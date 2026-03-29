# -*- mode: ruby -*-
# vi: set ft=ruby :

# ================================================================
#  Projet de Fin de Module — Architecture 3-Tiers Virtualisée
#  Outils  : Vagrant + VirtualBox
#  OS      : Ubuntu 22.04 LTS (jammy64)
#  Firewall: iptables avancé (style pfSense — zones WAN/LAN/DMZ)
# ================================================================
#
#  Topologie :
#
#    Internet (NAT)
#         │
#   ┌─────┴──────┐
#   │ VM1-Gateway│ eth0=NAT  eth1=LAN(192.168.10.1)  eth2=DMZ(192.168.100.1)
#   └─────┬──────┘
#         │
#   ┌─────┴────────────────────┐
#   │                          │
# LAN 192.168.10.0/24     DMZ 192.168.100.0/24
#   │                          │
# VM3-DB (192.168.10.10)   VM2-Web (192.168.100.10)
# MySQL                    Nginx + Node.js
# ================================================================

Vagrant.configure("2") do |config|

  config.vm.box             = "ubuntu/jammy64"
  config.vm.box_check_update = false

  # ── VM1 — Passerelle / Firewall (iptables style pfSense) ──
  config.vm.define "gateway" do |gw|
    gw.vm.hostname = "gateway"

    # LAN interne
    gw.vm.network "private_network",
      ip: "192.168.10.1",
      virtualbox__intnet: "lan_network"

    # DMZ interne
    gw.vm.network "private_network",
      ip: "192.168.100.1",
      virtualbox__intnet: "dmz_network"

    gw.vm.provider "virtualbox" do |vb|
      vb.name   = "VM1-Gateway-pfSense-like"
      vb.memory = 512
      vb.cpus   = 1
      # Activer le mode promiscuité pour le routage
      vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]
      vb.customize ["modifyvm", :id, "--nicpromisc3", "allow-all"]
    end

    gw.vm.provision "shell", path: "scripts/gateway.sh"
  end

  # ── VM2 — Serveur Web (Nginx + Node.js) ───────────────────
  config.vm.define "webserver" do |web|
    web.vm.hostname = "webserver"

    web.vm.network "private_network",
      ip: "192.168.100.10",
      virtualbox__intnet: "dmz_network"

    # Accès depuis la machine hôte
    web.vm.network "forwarded_port", guest: 80,   host: 8080
    web.vm.network "forwarded_port", guest: 3000, host: 3000

    web.vm.provider "virtualbox" do |vb|
      vb.name   = "VM2-WebServer"
      vb.memory = 1024
      vb.cpus   = 1
    end

    web.vm.provision "shell", path: "scripts/webserver.sh"
  end

  # ── VM3 — Serveur Base de Données (MySQL) ─────────────────
  config.vm.define "dbserver" do |db|
    db.vm.hostname = "dbserver"

    db.vm.network "private_network",
      ip: "192.168.10.10",
      virtualbox__intnet: "lan_network"

    db.vm.provider "virtualbox" do |vb|
      vb.name   = "VM3-DBServer"
      vb.memory = 1024
      vb.cpus   = 1
    end

    db.vm.provision "shell", path: "scripts/dbserver.sh"
  end

end
