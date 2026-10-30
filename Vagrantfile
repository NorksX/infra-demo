# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Creates the VMs for one environment by reading inventories/<env>/hosts.yml.
# This is the ONLY thing Vagrant does: clean Ubuntu 24.04 VMs with static IPs
# and a `deploy` user that accepts the project's SSH key (what cloud-init would
# do on a real cloud). Everything else is done by Ansible.
#
# Usage:
#   vagrant up                    # production (default)
#   $env:ENV="staging"; vagrant up  (PowerShell)  /  ENV=staging vagrant up
#   vagrant destroy -f

require 'yaml'

environment    = ENV['ENV'] || 'production'
# Multiplies every vb_memory from the inventory, e.g. VM_MEMORY_SCALE=1.5 on a
# bigger host. The inventory sizes fit a 16 GB laptop.
memory_scale   = (ENV['VM_MEMORY_SCALE'] || '1').to_f
root           = File.dirname(__FILE__)
inventory_file = File.join(root, 'inventories', environment, 'hosts.yml')
raise "Inventory not found: #{inventory_file} (ENV=production|staging)" unless File.exist?(inventory_file)

# Generate the deploy key pair once; it is gitignored.
key_file = File.join(root, 'files', 'deploy_key')
unless File.exist?("#{key_file}.pub")
  system('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'deploy@wordpress-platform', '-f', key_file) ||
    raise('ssh-keygen failed; generate files/deploy_key manually (see files/README.md)')
end
deploy_pubkey = File.read("#{key_file}.pub").strip

# Flatten every group's hosts into {name, ip, memory, cpus}.
servers = []
(YAML.load_file(inventory_file).dig('all', 'children') || {}).each_value do |group|
  (group['hosts'] || {}).each do |name, vars|
    vars ||= {}
    servers << { name: name, ip: vars['ansible_host'],
                 memory: ((vars['vb_memory'] || 512) * memory_scale).to_i, cpus: vars['vb_cpus'] || 1 }
  end
end

Vagrant.configure('2') do |config|
  config.vm.box = 'bento/ubuntu-24.04'
  config.vm.box_check_update = false
  config.vm.synced_folder '.', '/vagrant', disabled: true

  servers.each do |server|
    config.vm.define server[:name] do |node|
      node.vm.hostname = server[:name]
      node.vm.network 'private_network', ip: server[:ip]

      node.vm.provider 'virtualbox' do |vb|
        vb.name   = "wp-#{environment}-#{server[:name]}"
        vb.memory = server[:memory]
        vb.cpus   = server[:cpus]
        vb.linked_clone = true
        vb.customize ['modifyvm', :id, '--audio-driver', 'none']
      end

      node.vm.provision 'deploy-user', type: 'shell', inline: <<-SHELL
        set -e
        id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
        install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
        echo '#{deploy_pubkey}' > /home/deploy/.ssh/authorized_keys
        chown deploy:deploy /home/deploy/.ssh/authorized_keys
        chmod 0600 /home/deploy/.ssh/authorized_keys
        echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-deploy
        chmod 0440 /etc/sudoers.d/90-deploy
      SHELL
    end
  end
end
