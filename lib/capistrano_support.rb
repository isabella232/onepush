def log_sshkit(level, message)
  case level
  when :fatal
    level = SSHKit::Logger::FATAL
  when :error
    level = SSHKit::Logger::ERROR
  when :warn
    level = SSHKit::Logger::WARN
  when :info
    level = SSHKit::Logger::INFO
  when :debug
    level = SSHKit::Logger::DEBUG
  when :trace
    level = SSHKit::Logger::TRACE
  else
    raise "Bug"
  end
  SSHKit.config.output << SSHKit::LogMessage.new(level, message)
end

def fatal(message)
  log_sshkit(:fatal, message)
end

def notice(message)
  log_sshkit(:info, message)
end

def info(message)
  log_sshkit(:info, message)
end

def fatal_and_abort(message)
  fatal(message)
  abort
end


def check_manifest_requirements(manifest)
  if !manifest['about']
    fatal_and_abort("There must be an 'about' section in the manifest")
  end
  ['id', 'type', 'domain_names'].each do |key|
    if !manifest['about'][key]
      fatal_and_abort("The '#{key}' option must be set in the 'about' section")
    end
  end
  if setup = manifest['setup']
    if setup['passenger_enterprise'] && !setup['passenger_enterprise_download_token']
      fatal_and_abort("If you set passenger_enterprise to true, then you must also " +
        "set passenger_enterprise_download_token")
    end
  end
end


def sudo(host, command)
  execute(wrap_in_sudo(host, command))
end

def sudo_test(host, command)
  test(wrap_in_sudo(host, command))
end

def sudo_capture(host, command)
  capture(wrap_in_sudo(host, command))
end

def sudo_download(host, path, io)
  io.write(sudo_capture(host, "cat #{path}"))
end

def sudo_upload(host, io, path)
  mktempdir(host) do |tmpdir|
    upload!(io, "#{tmpdir}/file")
    sudo(host, "chown root: #{tmpdir}/file && mv #{tmpdir}/file #{path}")
  end
end

def wrap_in_sudo(host, command)
  if host.user == 'root'
    b(command)
  else
    if !host.properties.fetch(:sudo_checked)
      if test("[[ -e /usr/bin/sudo ]]")
        if !test("/usr/bin/sudo -k -n true")
          fatal_and_abort "Sudo needs a password for the '#{host.user}' user. However, Onepush " +
            "needs sudo to *not* ask for a password. Please *temporarily* configure " +
            "sudo to allow the '#{host.user}' user to run it without a password.\n\n" +
            "Open the sudo configuration file:\n" +
            "  sudo visudo\n\n" +
            "Then insert:\n" +
            "  # Remove this entry later. Onepush only needs it temporarily.\n" +
            "  #{host.user} ALL=(ALL) NOPASSWD: ALL"
        end
        host.properties.set(:sudo_checked, true)
      else
        fatal_and_abort "Onepush requires 'sudo' to be installed on the server. Please install it first."
      end
    end
    "/usr/bin/sudo -k -n -H #{b command}"
  end
end

def b(script)
  full_script = "set -o pipefail && #{script}"
  "/bin/bash -c #{Shellwords.escape(full_script)}"
end

def mktempdir(host)
  tmpdir = capture("mktemp -d /tmp/onepush.XXXXXXXX").strip
  begin
    yield tmpdir
  ensure
    sudo(host, "rm -rf #{tmpdir}")
  end
end

def create_user(host, name)
  case host.properties.fetch(:os_class)
  when :redhat
    sudo(host, "adduser #{name} && usermod -L #{name}")
  when :debian
    sudo(host, "adduser --disabled-password --gecos #{name} #{name}")
  else
    raise "Bug"
  end
end


def cache(host, name)
  if result = host.properties.fetch("cache_#{name}")
    result[0]
  else
    result = [yield]
    host.properties.set("cache_#{name}", result)
    result[0]
  end
end

def clear_cache(host, name)
  host.properties.set("cache_#{name}", nil)
end


def apt_get_update(host)
  sudo(host, "apt-get update && touch /var/lib/apt/periodic/update-success-stamp")
  host.properties.set(:apt_get_updated, true)
end

def apt_get_install(host, packages)
  packages = filter_non_installed_packages(host, packages)
  if !packages.empty?
    if !host.properties.fetch(:apt_get_updated)
      two_days = 2 * 60 * 60 * 24
      script = "[[ -e /var/lib/apt/periodic/update-success-stamp ]] && " +
        "timestamp=`stat -c %Y /var/lib/apt/periodic/update-success-stamp` && " +
        "threshold=`date +%s` && " +
        "(( threshold = threshold - #{two_days} )) && " +
        '[[ "$timestamp" -gt "$threshold" ]]'
      if !test(script)
        apt_get_update(host)
      end
    end
    sudo(host, "apt-get install -y #{packages.join(' ')}")
  end
  packages.size
end

def yum_install(host, packages)
  packages = filter_non_installed_packages(host, packages)
  if !packages.empty?
    sudo(host, "yum install -y #{packages.join(' ')}")
  end
  packages.size
end

def check_packages_installed(host, names)
  result = {}
  case host.properties.fetch(:os_class)
  when :redhat
    installed = capture("rpm -q #{names.join(' ')} 2>&1 | grep 'is not installed$'; true")
    not_installed = installed.split("\n").map { |x| x.sub(/^package (.+) is not installed$/, '\1') }
    names.each do |name|
      result[name] = !not_installed.include?(name)
    end
  when :debian
    installed = capture("dpkg-query -s #{names.join(' ')} 2>/dev/null | grep '^Package: '; true")
    installed = installed.gsub(/^Package: /, '').split("\n")
    names.each do |name|
      result[name] = installed.include?(name)
    end
  else
    raise "Bug"
  end
  result
end

def filter_non_installed_packages(host, names)
  result = []
  check_packages_installed(host, names).each_pair do |name, installed|
    if !installed
      result << name
    end
  end
  result
end


def autodetect_nginx(host)
  cache(host, :nginx) do
    result = {}
    if test("[[ -e /usr/sbin/nginx && -e /etc/nginx/nginx.conf ]]")
      result[:installed_from_system_package] = true
      result[:binary]      = "/usr/bin/nginx"
      result[:config_file] = "/etc/nginx/nginx.conf"
      result[:configtest_command] = "/etc/init.d/nginx configtest"
      result[:restart_command] = "/etc/init.d/nginx restart"
      result
    else
      files = capture("ls -1 /opt/*/*/nginx 2>/dev/null", :raise_on_non_zero_exit => false).split("\n")
      if files.any?
        result[:binary] = files[0]
        result[:config_file] = File.absolute_path(File.dirname(files[0]) + "/../conf/nginx.conf")
        result[:configtest_command] = "#{files[0]} -t"
        has_runit_service = files[0] == "/opt/nginx/sbin/nginx" &&
          test("grep /opt/nginx/sbin/nginx /etc/service/nginx/run 2>&1")
        if has_runit_service
          result[:restart_command] = "sv restart /etc/service/nginx"
        end
      else
        nil
      end
    end
  end
end

def autodetect_nginx!(host)
  autodetect_nginx(host) ||
    fatal_and_abort("Cannot autodetect Nginx. This is probably a bug in Onepush. " +
      "Please report this to the authors.")
end

def autodetect_passenger(host)
  cache(host, :passenger) do
    ruby   = autodetect_ruby_interpreter_for_passenger(host)
    result = { :ruby => ruby }
    if test("[[ -e /usr/bin/passenger-config ]]")
      result[:installed_from_system_package] = true
      result[:bindir]            = "/usr/bin"
      result[:nginx_installer]   = "/usr/bin/passenger-install-nginx-module"
      result[:apache2_installer] = "/usr/bin/passenger-install-apache2-module"
      result[:config_command]    = "/usr/bin/passenger-config"
      result
    elsif test("[[ -e /opt/passenger/current/bin/passenger-config ]]")
      result[:bindir]            = "/opt/passenger/current/bin"
      result[:nginx_installer]   = "#{ruby} /opt/passenger/current/bin/passenger-install-nginx-module".strip
      result[:apache2_installer] = "#{ruby} /opt/passenger/current/bin/passenger-install-apache2-module".strip
      result[:config_command]    = "#{ruby} /opt/passenger/current/bin/passenger-config".strip
      result
    else
      passenger_config = capture("which passenger-config", :raise_on_non_zero_exit => false).strip
      if passenger_config.empty?
        nil
      else
        bindir = File.dirname(passenger_config)
        result[:bindir] = bindir
        result[:nginx_installer]   = "#{bindir}/passenger-install-nginx-module"
        result[:apache2_installer] = "#{bindir}/passenger-install-apache2-module"
        result[:config_command]    = passenger_config
        result
      end
    end
  end
end

def autodetect_passenger!(host)
  autodetect_passenger(host) || \
    fatal_and_abort("Cannot autodetect Phusion Passenger. This is probably a bug in Onepush. " +
      "Please report this to the authors.")
end

def autodetect_ruby_interpreter_for_passenger(host)
  cache(host, :ruby) do
    if MANIFEST['about']['type'] == 'ruby'
      # Since install_passenger_source_dependencies installs RVM
      # if the language is Ruby (and thus, does not install Rake
      # through the OS package manager), we must give RVM precedence
      # here.
      possibilities = [
        "/usr/local/rvm/wrappers/default/ruby",
        "/usr/bin/ruby"
      ]
    else
      possibilities = [
        "/usr/bin/ruby",
        "/usr/local/rvm/wrappers/default/ruby"
      ]
    end
    result = nil
    possibilities.each do |possibility|
      if test("[[ -e #{possibility} ]]")
        result = possibility
        break
      end
    end
    result
  end
end


def autodetect_ruby_interpreter_for_passenger!(host)
  autodetect_ruby_interpreter_for_passenger(host) || \
    fatal_and_abort("Unable to find a Ruby interpreter on the system. This is probably " +
      "a bug in Onepush. Please report this to the authors.")
end


def check_file_change(host, path)
  md5_old = sudo_capture(host, "md5sum #{path} 2>/dev/null; true").strip
  yield
  md5_new = sudo_capture(host, "md5sum #{path}").strip
  md5_old != md5_new
end


def _check_server_setup(host)
  id = MANIFEST['about']['id']

  set :application, id

  app_dir = capture("readlink /etc/onepush/apps/#{id}; true").strip
  if app_dir.empty?
    fatal_and_abort "The server has not been setup for your app yet. Please run 'onepush setup'."
  end
  set(:deploy_to, app_dir)
  set(:repo_url, "#{app_dir}/onepush_repo")

  io = StringIO.new
  download!("#{app_dir}/onepush-setup.json", io)
  manifest = JSON.parse(io.string)
  set(:onepush_setup, manifest)

  if manifest['setup']['ruby_version']
    set :rvm_ruby_version, manifest['setup']['ruby_version']
  end

  invoke 'rvm:hook'
  rvm_path = fetch(:rvm_path)
  ruby_version = fetch(:rvm_ruby_version)
  if !test("#{rvm_path}/bin/rvm #{ruby_version} do ruby --version")
    fatal_and_abort "Your app requires #{ruby_version}, but it isn't installed yet. Please run 'onepush setup'."
  end
end
