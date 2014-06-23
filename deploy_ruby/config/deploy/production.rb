require 'json'
require 'uri'

abort "At least one deploy address must be specified" if !ENV['DEPLOY_ADDRESSES']
JSON.parse(ENV['DEPLOY_ADDRESSES']).each do |address|
  uri = URI.parse("scheme://#{address}")
  hostname = uri.hostname.dup
  hostname << ":#{uri.port}" if uri.port
  server(hostname, :user => uri.user || "root", :roles => ['web', 'app', 'db'])
end

keys = []
if ENV['VAGRANT_KEY']
  keys << File.absolute_path(File.dirname(__FILE__) + "/../../../lib/vagrant_insecure_key")
end
if ENV['SSH_KEYS']
  JSON.parse(ENV['SSH_KEYS']).each do |filename|
    keys << filename
  end
end

set :ssh_options, { :keys => keys }
