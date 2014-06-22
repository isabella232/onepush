task :create_app_user => :install_essentials do
  notice "Creating user account for app..."
  on roles(:app) do |host|
    name = SETUP['user']

    if !test("id -u #{name} >/dev/null 2>&1")
      create_user(host, name)
    end
    case ABOUT['type']
    when 'ruby'
      case SETUP['ruby_manager']
      when 'rvm'
        sudo(host, "usermod -a -G rvm #{name}")
      end
    end

    if sudo_test(host, "[[ -e /home/#{name}/.ssh/authorized_keys ]]")
      authorized_keys_file = sudo_download_to_string(host, "/home/#{name}/.ssh/authorized_keys")
    else
      authorized_keys_file = ""
    end
    authorized_keys = authorized_keys_file.split("\n", -1)
    add_pubkey_to_array(authorized_keys, "~/.ssh/id_rsa.pub")
    add_pubkey_to_array(authorized_keys, "~/.ssh/id_dsa.pub")
    if authorized_keys.join("\n").strip != authorized_keys_file.strip
      io = StringIO.new
      io.write(authorized_keys.join("\n"))
      io.rewind

      sudo(host, "mkdir -p /home/#{name}/.ssh")
      sudo_upload(host, io, "/home/#{name}/.ssh/authorized_keys",
        :chown => "#{name}:",
        :chmod => 644)
      sudo(host, "chown #{name}: /home/#{name}/.ssh && " +
        "chmod 700 /home/#{name}/.ssh")
    end
  end
end

def add_pubkey_to_array(keys, path)
  path = File.expand_path(path)
  if File.exist?(path)
    File.read(path).split("\n").each do |key|
      if !keys.include?(key)
        keys << key
      end
    end
  end
end

task :create_app_dir => [:install_essentials, :create_app_user] do
  notice "Creating directory for app..."
  path  = SETUP['app_dir']
  owner = SETUP['user']

  primary_dirs     = "#{path} #{path}/releases #{path}/shared #{path}"
  onepush_repo_path = "#{path}/onepush_repo"
  repo_dirs        = "#{path}/repo #{onepush_repo_path}"

  on roles(:app) do |host|
    sudo(host, "mkdir -p #{primary_dirs} && chown #{owner}: #{primary_dirs} && chmod u=rwx,g=rx,o=x #{primary_dirs}")
    sudo(host, "mkdir -p #{path}/shared/config && chown #{owner}: #{path}/shared/config")

    sudo(host, "mkdir -p #{repo_dirs} && chown #{owner}: #{repo_dirs} && chmod u=rwx,g=,o= #{repo_dirs}")
    sudo(host, "cd #{onepush_repo_path} && if ! [[ -e HEAD ]]; then sudo -u #{owner} git init --bare; fi")
  end
end

task :create_app_vhost => [:create_app_dir] do
  notice "Creating web server virtual host for app..."
  app_dir = SETUP['app_dir']
  user    = SETUP['user']
  local_conf = "#{app_dir}/shared/config/nginx-vhost-local.conf"

  config = StringIO.new
  config.puts "# Autogenerated by Onepush. Do not edit. Changes will be overwritten. Edit nginx-vhost-local.conf instead."
  config.puts "server {"
  config.puts "    listen 80;"
  config.puts "    server_name #{ABOUT['domain_names']};"
  config.puts "    root #{app_dir}/current/public;"
  if SETUP['install_passenger']
    config.puts "    passenger_enabled on;"
    config.puts "    passenger_user #{user};"
  end
  config.puts "    include #{local_conf};"
  config.puts "}"
  config.rewind

  local = StringIO.new
  local.puts "# You can put custom Nginx configuration here. This file will not be overrwitten by Onepush."
  local.rewind

  on roles(:app) do |host|
    changed = check_file_change(host, "#{app_dir}/shared/config/nginx-vhost.conf") do
      sudo_upload(host, config, "#{app_dir}/shared/config/nginx-vhost.conf")
      sudo(host, "chown #{user}: #{app_dir}/shared/config/nginx-vhost.conf && " +
        "chmod 600 #{app_dir}/shared/config/nginx-vhost.conf")
    end
    if changed
      sudo(host, "touch /var/run/onepush/restart_web_server")
    end

    if sudo_test(host, "[[ ! -e #{local_conf} ]]")
      sudo_upload(host, local, local_conf)
      sudo(host, "chown #{user}: #{local_conf} && " +
        "chmod 640 #{local_conf}")
    end
  end
end
