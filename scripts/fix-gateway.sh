#!/bin/bash
# ================================================================
#  CORRECTIF RAPIDE — Gateway (interfaces enp0s3/enp0s8/enp0s9)
#  Exécuter directement sur VM1 : sudo bash fix-gateway.sh
# ================================================================

set -e
echo "================================================================"
echo "  CORRECTIF FIREWALL — Interfaces enp0s3/enp0s8/enp0s9"
echo "================================================================"

WAN="enp0s3"
LAN="enp0s8"
DMZ="enp0s9"

echo "WAN=$WAN | LAN=$LAN | DMZ=$DMZ"
echo ""

# Vider toutes les règles
iptables -F
iptables -X
iptables -Z
iptables -t nat    -F; iptables -t nat    -X
iptables -t mangle -F; iptables -t mangle -X

# Politiques par défaut
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT

# Chaînes personnalisées
iptables -N LOG_DROP
iptables -A LOG_DROP -m limit --limit 10/min --limit-burst 20 \
  -j LOG --log-prefix "[FW-DROP] " --log-level 4
iptables -A LOG_DROP -j DROP

iptables -N INVALID_DROP
iptables -A INVALID_DROP -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "[FW-INVALID] " --log-level 4
iptables -A INVALID_DROP -j DROP

iptables -N SYNFLOOD_PROTECT
iptables -A SYNFLOOD_PROTECT -m limit --limit 25/s --limit-burst 50 -j RETURN
iptables -A SYNFLOOD_PROTECT -j LOG_DROP

# ── INPUT ────────────────────────────────────────────────────
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j INVALID_DROP
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --syn -j SYNFLOOD_PROTECT
iptables -A INPUT -i $LAN -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 10/s --limit-burst 20 -j ACCEPT
iptables -A INPUT -i $WAN -p udp --dport 68 -j ACCEPT
iptables -A INPUT -j LOG_DROP

# ── FORWARD ──────────────────────────────────────────────────
iptables -A FORWARD -m conntrack --ctstate INVALID    -j INVALID_DROP
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# LAN → WAN (Internet)
iptables -A FORWARD -i $LAN -o $WAN -m conntrack --ctstate NEW -j ACCEPT

# LAN → DMZ (port 80)
iptables -A FORWARD -i $LAN -o $DMZ -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i $LAN -o $DMZ -p icmp -j ACCEPT

# DMZ → WAN (HTTP/HTTPS/DNS pour apt, npm)
iptables -A FORWARD -i $DMZ -o $WAN -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i $DMZ -o $WAN -p udp --dport 53  -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i $DMZ -o $WAN -p tcp --dport 53  -m conntrack --ctstate NEW -j ACCEPT

# DMZ → LAN MySQL uniquement
iptables -A FORWARD -i $DMZ -o $LAN -p tcp --dport 3306 -d 192.168.10.10 -m conntrack --ctstate NEW -j ACCEPT

# DMZ → LAN tout le reste : BLOQUÉ
iptables -A FORWARD -i $DMZ -o $LAN -j LOG_DROP

# WAN → DMZ (port 80/443)
iptables -A FORWARD -i $WAN -o $DMZ -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT

# WAN → LAN : BLOQUÉ
iptables -A FORWARD -i $WAN -o $LAN -j LOG_DROP

# Tout autre FORWARD : BLOQUÉ
iptables -A FORWARD -j LOG_DROP

# ── NAT ──────────────────────────────────────────────────────
iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE
iptables -t nat -A PREROUTING  -i $WAN -p tcp --dport 80  -j DNAT --to-destination 192.168.100.10:80
iptables -t nat -A PREROUTING  -i $WAN -p tcp --dport 443 -j DNAT --to-destination 192.168.100.10:443

# ── Sauvegarder ──────────────────────────────────────────────
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo ""
echo "✅ Firewall corrigé ! Vérification :"
echo ""
echo "── FORWARD rules ────────────────────"
iptables -L FORWARD -v -n --line-numbers
echo ""
echo "── NAT ──────────────────────────────"
iptables -t nat -L -v -n
echo ""
echo "Test de connectivité :"
ping -c2 -W2 192.168.10.10  && echo "✅ LAN (DB) joignable" || echo "❌ LAN (DB) non joignable"
ping -c2 -W2 192.168.100.10 && echo "✅ DMZ (Web) joignable" || echo "❌ DMZ (Web) non joignable"
