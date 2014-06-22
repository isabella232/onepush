task :install_additional_services => :install_essentials do
  notice "Installing additional services..."

  on roles(:app) do |host|
    if MANIFEST['memcached']
      case host.properties.fetch(:os_class)
      when :redhat
        yum_install(host, %w(memcached))
      when :debian
        apt_get_install(host, %w(memcached))
      else
        raise "Bug"
      end
    end
    if MANIFEST['redis']
      case host.properties.fetch(:os_class)
      when :redhat
        yum_install(host, %w(redis))
      when :debian
        apt_get_install(host, %w(redis-server))
      else
        raise "Bug"
      end
    end
  end
end
