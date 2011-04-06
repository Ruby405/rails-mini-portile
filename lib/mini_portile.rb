require 'rbconfig'
require 'net/http'
require 'fileutils'
require 'tempfile'
require 'digest/md5'

class MiniPortile
  attr_reader :name, :version
  attr_writer :configure_options
  attr_accessor :host, :files, :target, :logger

  def initialize(name, version)
    @name = name
    @version = version
    @target = 'ports'
    @files = []
    @logger = STDOUT

    @host = RbConfig::CONFIG['arch']
  end

  def download
    @files.each do |url|
      filename = File.basename(url)
      download_file(url, File.join(archives_path, filename))
    end
  end

  def extract
    @files.each do |url|
      filename = File.basename(url)
      extract_file(File.join(archives_path, filename), tmp_path)
    end
  end

  def configure_options
    @configure_options ||= configure_defaults
  end

  def configure
    return if configured?

    md5_file = File.join(tmp_path, 'configure.md5')
    digest   = Digest::MD5.hexdigest(computed_options)
    File.open(md5_file, "w") { |f| f.write digest }

    execute('configure', %Q(sh configure #{computed_options}))
  end

  def compile
    execute('compile', 'make')
  end

  def install
    return if installed?
    execute('install', %Q(make install))
  end

  def downloaded?
    missing = @files.detect do |url|
      filename = File.basename(url)
      !File.exist?(File.join(archives_path, filename))
    end

    missing ? false : true
  end

  def configured?
    configure = File.join(work_path, 'configure')
    makefile  = File.join(work_path, 'Makefile')
    md5_file  = File.join(tmp_path, 'configure.md5')

    stored_md5  = File.exist?(md5_file) ? File.read(md5_file) : ""
    current_md5 = Digest::MD5.hexdigest(computed_options)

    (current_md5 == stored_md5) && newer?(makefile, configure)
  end

  def installed?
    makefile  = File.join(work_path, 'Makefile')
    target_dir = Dir.glob("#{port_path}/*").find { |d| File.directory?(d) }

    newer?(target_dir, makefile)
  end

  def cook
    download unless downloaded?
    extract
    configure unless configured?
    compile
    install unless installed?

    return true
  end

  def activate
    vars = {
      'PATH'          => File.join(port_path, 'bin'),
      'CPATH'         => File.join(port_path, 'include'),
      'LIBRARY_PATH'  => File.join(port_path, 'lib')
    }.reject { |env, path| !File.directory?(path) }

    output "Activating #{@name} #{@version} (from #{port_path})..."
    vars.each do |var, path|
      full_path = File.expand_path(path)

      # turn into a valid Windows path (if required)
      full_path.gsub!(File::SEPARATOR, File::ALT_SEPARATOR) if File::ALT_SEPARATOR

      # save current variable value
      old_value = ENV[var] || ''

      unless old_value.include?(full_path)
        ENV[var] = "#{full_path}#{File::PATH_SEPARATOR}#{old_value}"
      end
    end
  end

private

  def tmp_path
    @tmp_path ||= "tmp/#{@host}/ports/#{@name}/#{@version}"
  end

  def port_path
    @port_path ||= "#{@target}/#{@host}/#{@name}/#{@version}"
  end

  def archives_path
    @archives_path ||= "#{@target}/archives"
  end

  def work_path
    @work_path ||= begin
      Dir.glob("#{tmp_path}/*").find { |d| File.directory?(d) }
    end
  end

  def configure_defaults
    [
      "--host=#{@host}",    # build for specific target (host)
      "--enable-static",    # build static library
      "--disable-shared"    # disable generation of shared object
    ]
  end

  def configure_prefix
    "--prefix=#{File.expand_path(port_path)}"
  end

  def computed_options
    [
      configure_options,     # customized or default options
      configure_prefix,      # installation target
    ].flatten.join(' ')
  end

  def log_file(action)
    File.join(tmp_path, "#{action}.log")
  end

  def tar_exe
    @@tar_exe ||= begin
      dev_null = RbConfig::CONFIG['host_os'] =~ /mingw|mswin/ ? 'NUL' : '/dev/null'
      %w[tar bsdtar basic-bsdtar].find { |c|
        system("#{c} --version >> #{dev_null} 2>&1")
      }
    end
  end

  def extract_file(file, target)
    filename = File.basename(file)
    FileUtils.mkdir_p target

    message "Extracting #{filename} into #{target}... "
    result = `#{tar_exe} xf #{file} -C #{target} 2>&1`
    if $?.success?
      output "OK"
    else
      output "ERROR"
      output result
      raise "Failed to complete extract task"
    end
  end

  def execute(action, command)
    log        = log_file(action)
    log_out    = File.expand_path(log)
    redirected = command << " >#{log_out} 2>&1"

    Dir.chdir work_path do
      message "Running '#{action}' for #{@name} #{@version}... "
      system redirected
      if $?.success?
        output "OK"
        return true
      else
        output "ERROR, review '#{log}' to see what happened."
        raise "Failed to complete #{action} task"
      end
    end
  end

  def newer?(target, checkpoint)
    if (target && File.exist?(target)) && (checkpoint && File.exist?(checkpoint))
      File.mtime(target) > File.mtime(checkpoint)
    else
      false
    end
  end

  # print out a message with the logger
  def message(text)
    @logger.print text
    @logger.flush
  end

  # print out a message using the logger but return to a new line
  def output(text = "")
    @logger.puts text
    @logger.flush
  end

  # Slighly modified from RubyInstaller uri_ext, Rubinius configure
  # and adaptations of Wayne's RailsInstaller
  def download_file(url, full_path, count = 3)
    return if File.exist?(full_path)
    filename = File.basename(full_path)

    begin

      if ENV['http_proxy']
        protocol, userinfo, host, port  = URI::split(ENV['http_proxy'])
        proxy_user, proxy_pass = userinfo.split(/:/) if userinfo
        http = Net::HTTP::Proxy(host, port, proxy_user, proxy_pass)
      else
        http = Net::HTTP
      end

      message "Downloading #{filename} "
      http.get_response(URI.parse(url)) do |response|
        case response
        when Net::HTTPNotFound
          output "404 - Not Found"
          return false

        when Net::HTTPClientError
          output "Error: Client Error: #{response.inspect}"
          return false

        when Net::HTTPRedirection
          raise "Too many redirections for the original URL, halting." if count <= 0
          url = response["location"]
          return download_file(url, full_path, count - 1)

        when Net::HTTPOK
          temp_file = Tempfile.new("download-#{filename}")
          temp_file.binmode

          size = 0
          progress = 0
          total = response.header["Content-Length"].to_i

          response.read_body do |chunk|
            temp_file << chunk
            size += chunk.size
            new_progress = (size * 100) / total
            unless new_progress == progress
              message "\rDownloading %s (%3d%%) " % [filename, new_progress]
            end
            progress = new_progress
          end

          output

          temp_file.close
          File.unlink full_path if File.exists?(full_path)
          FileUtils.mkdir_p File.dirname(full_path)
          FileUtils.mv temp_file.path, full_path, :force => true
        end
      end

    rescue Exception => e
      File.unlink full_path if File.exists?(full_path)
      output "ERROR: #{e.message}"
      raise "Failed to complete download task"
    end
  end
end
