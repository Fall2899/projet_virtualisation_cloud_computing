#!/bin/bash
# ================================================================
#  VM1 — Passerelle / Firewall (iptables avancé style pfSense)
#  Zones  : WAN (eth0/NAT)  |  LAN (eth1)  |  DMZ (eth2)
#  Fonctions : NAT, routage inter-zones, logging, stateful rules
# ================================================================

set -e

# ── Couleurs pour les logs ────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

echo ""
echo "================================================================"
echo "  VM1 — Firewall iptables (style pfSense) — Provisionnement"
echo "================================================================"
echo ""

# ── 1. Paquets nécessaires ───────────────────────────────────
info "Installation des paquets..."
apt-get update -qq

# Pré-répondre aux questions de iptables-persistent (évite le blocage interactif)
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  iptables iptables-persistent netfilter-persistent \
  net-tools curl tcpdump ulogd2
log "Paquets installés."

# ── 2. Interfaces réseau ─────────────────────────────────────
# eth0 = WAN (NAT Vagrant — accès Internet)
# eth1 = LAN (192.168.10.0/24 — réseau interne privé)
# eth2 = DMZ (192.168.100.0/24 — zone démilitarisée)
WAN="enp0s3"
LAN="enp0s8"
DMZ="enp0s9"

info "Interfaces : WAN=$WAN | LAN=$LAN | DMZ=$DMZ"

# ── 3. Activer le routage IP ──────────────────────────────────
info "Activation du routage IP..."
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1"          >> /etc/sysctl.conf
echo "net.ipv4.conf.all.rp_filter=1"  >> /etc/sysctl.conf   # Anti-spoofing
echo "net.ipv4.conf.all.send_redirects=0" >> /etc/sysctl.conf
echo "net.ipv4.conf.all.accept_redirects=0" >> /etc/sysctl.conf
sysctl -p /etc/sysctl.conf > /dev/null
log "Routage IP + protections anti-spoofing activés."

# ── 4. Configurer ulogd2 (logging des paquets droppés) ────────
info "Configuration du logging (ulogd2)..."
mkdir -p /var/log/firewall
cat > /etc/ulogd.conf << 'ULOG'
[global]
logfile="/var/log/ulogd.log"
loglevel=3

stack=log1:NFLOG,base1:BASE,ifi1:IFINDEX,ip2str1:IP2STR,print1:PRINTPKT,emu1:LOGEMU

[log1]
group=1

[emu1]
file="/var/log/firewall/dropped.log"
sync=1
ULOG
systemctl enable ulogd2 2>/dev/null || true
systemctl restart ulogd2 2>/dev/null || true
log "Logging des paquets droppés → /var/log/firewall/dropped.log"

# ── 5. Règles iptables — FLUSH complet ───────────────────────
info "Nettoyage des règles existantes..."
iptables -F
iptables -X
iptables -Z
iptables -t nat    -F; iptables -t nat    -X
iptables -t mangle -F; iptables -t mangle -X

# ── 6. Politiques par défaut (style pfSense : tout bloquer) ──
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT
log "Politiques par défaut : INPUT=DROP | FORWARD=DROP | OUTPUT=ACCEPT"

# ================================================================
#  CHAÎNES PERSONNALISÉES (style pfSense — règles par zone)
# ================================================================

# Chaîne : paquets invalides → LOG + DROP
iptables -N INVALID_DROP
iptables -A INVALID_DROP -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "[FW-INVALID] " --log-level 4
iptables -A INVALID_DROP -j DROP

# Chaîne : paquets droppés → LOG + DROP
iptables -N LOG_DROP
iptables -A LOG_DROP -m limit --limit 10/min --limit-burst 20 \
  -j LOG --log-prefix "[FW-DROP] " --log-level 4
iptables -A LOG_DROP -j DROP

# Chaîne : paquets acceptés → LOG + ACCEPT (optionnel, désactivé par défaut)
iptables -N LOG_ACCEPT
iptables -A LOG_ACCEPT -m limit --limit 20/min --limit-burst 50 \
  -j LOG --log-prefix "[FW-ACCEPT] " --log-level 6
iptables -A LOG_ACCEPT -j ACCEPT

# Chaîne : protection anti-scan de ports (SYN flood)
iptables -N SYNFLOOD_PROTECT
iptables -A SYNFLOOD_PROTECT -m limit --limit 25/s --limit-burst 50 -j RETURN
iptables -A SYNFLOOD_PROTECT -j LOG_DROP

log "Chaînes personnalisées créées (INVALID_DROP, LOG_DROP, SYNFLOOD_PROTECT)."

# ================================================================
#  TABLE FILTER — INPUT (trafic à destination du firewall lui-même)
# ================================================================

# Loopback toujours autorisé
iptables -A INPUT -i lo -j ACCEPT

# Paquets invalides → DROP immédiat
iptables -A INPUT -m conntrack --ctstate INVALID -j INVALID_DROP

# Connexions établies / liées (stateful)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Protection SYN flood sur nouvelles connexions TCP
iptables -A INPUT -p tcp --syn -j SYNFLOOD_PROTECT

# ── Zone WAN → Gateway ──────────────────────────────────────
# SSH uniquement depuis le LAN (pas depuis WAN)
iptables -A INPUT -i $LAN -p tcp --dport 22 \
  -m conntrack --ctstate NEW -j ACCEPT

# ICMP : ping limité (rate limiting style pfSense)
iptables -A INPUT -p icmp --icmp-type echo-request \
  -m limit --limit 10/s --limit-burst 20 -j ACCEPT
iptables -A INPUT -p icmp -j LOG_DROP

# DHCP depuis les réseaux internes (si besoin)
iptables -A INPUT -i $LAN -p udp --dport 67 -j ACCEPT
iptables -A INPUT -i $DMZ -p udp --dport 67 -j ACCEPT

# Tout le reste entrant → LOG + DROP
iptables -A INPUT -j LOG_DROP

log "Règles INPUT configurées (SSH-LAN-only, ICMP rate-limit, SYN-flood)."

# ================================================================
#  TABLE FILTER — FORWARD (routage inter-zones)
#  Logique pfSense : règles par interface SOURCE
# ================================================================

# Paquets invalides
iptables -A FORWARD -m conntrack --ctstate INVALID -j INVALID_DROP

# Connexions établies / liées (stateful — return traffic)
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── ZONE LAN → WAN ─────────────────────────────────────────
# Le LAN a accès complet à Internet (HTTP, HTTPS, DNS)
iptables -A FORWARD -i $LAN -o $WAN \
  -m conntrack --ctstate NEW -j ACCEPT

# ── ZONE LAN → DMZ ─────────────────────────────────────────
# Le LAN peut accéder au serveur web (port 80 uniquement)
iptables -A FORWARD -i $LAN -o $DMZ \
  -p tcp --dport 80 \
  -m conntrack --ctstate NEW -j ACCEPT

# Le LAN peut pinguer la DMZ (pour tests)
iptables -A FORWARD -i $LAN -o $DMZ \
  -p icmp --icmp-type echo-request \
  -m limit --limit 5/s -j ACCEPT

# ── ZONE DMZ → WAN ─────────────────────────────────────────
# La DMZ peut accéder à Internet (npm install, apt, etc.)
# Limité : HTTP/HTTPS/DNS uniquement (pas de sortie arbitraire)
iptables -A FORWARD -i $DMZ -o $WAN \
  -p tcp -m multiport --dports 80,443 \
  -m conntrack --ctstate NEW -j ACCEPT

iptables -A FORWARD -i $DMZ -o $WAN \
  -p udp --dport 53 \
  -m conntrack --ctstate NEW -j ACCEPT

iptables -A FORWARD -i $DMZ -o $WAN \
  -p tcp --dport 53 \
  -m conntrack --ctstate NEW -j ACCEPT

# ── ZONE DMZ → LAN ─────────────────────────────────────────
# La DMZ peut accéder à la DB MySQL (port 3306) — LAN uniquement
# (Le serveur web doit joindre la DB)
iptables -A FORWARD -i $DMZ -o $LAN \
  -p tcp --dport 3306 \
  -d 192.168.10.10 \
  -m conntrack --ctstate NEW -j ACCEPT

# Tout autre trafic DMZ→LAN est BLOQUÉ (isolation DMZ)
iptables -A FORWARD -i $DMZ -o $LAN -j LOG_DROP

# ── ZONE WAN → DMZ ─────────────────────────────────────────
# Internet peut accéder au serveur web (ports 80 et 443)
iptables -A FORWARD -i $WAN -o $DMZ \
  -p tcp -m multiport --dports 80,443 \
  -m conntrack --ctstate NEW -j ACCEPT

# ── ZONE WAN → LAN ─────────────────────────────────────────
# Internet ne peut PAS accéder au LAN (toujours bloqué)
iptables -A FORWARD -i $WAN -o $LAN -j LOG_DROP

# Tout autre FORWARD non matché → LOG + DROP
iptables -A FORWARD -j LOG_DROP

log "Règles FORWARD configurées (zones WAN/LAN/DMZ isolées)."

# ================================================================
#  TABLE NAT
# ================================================================

# MASQUERADE : tout ce qui sort par le WAN est NAT-é
iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE

# Port forwarding : WAN:80 → DMZ WebServer:80 (DNAT)
iptables -t nat -A PREROUTING -i $WAN \
  -p tcp --dport 80 \
  -j DNAT --to-destination 192.168.100.10:80

# Port forwarding : WAN:443 → DMZ WebServer:443 (DNAT)
iptables -t nat -A PREROUTING -i $WAN \
  -p tcp --dport 443 \
  -j DNAT --to-destination 192.168.100.10:443

log "NAT configuré (MASQUERADE WAN, DNAT 80/443 → DMZ)."

# ================================================================
#  TABLE MANGLE — QoS / Marquage (optionnel, style pfSense)
# ================================================================

# Marquer le trafic LAN (DSCP CS1 — priorité basse pour le bulk)
iptables -t mangle -A FORWARD -i $LAN -o $WAN \
  -p tcp -m multiport --dports 80,443 \
  -j DSCP --set-dscp-class CS1

# Marquer le trafic SSH (DSCP CS6 — haute priorité)
iptables -t mangle -A FORWARD -p tcp --dport 22 \
  -j DSCP --set-dscp-class CS6

log "Marquage QoS (DSCP) configuré."

# ── 7. Sauvegarder les règles (persistance au reboot) ─────────
info "Sauvegarde des règles iptables..."
mkdir -p /etc/iptables
iptables-save  > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
log "Règles sauvegardées dans /etc/iptables/rules.v4"

# ── 8. Script de monitoring du firewall ──────────────────────
cat > /usr/local/bin/fw-status << 'FWSTATUS'
#!/bin/bash
# Script de monitoring — affiche l'état du firewall
echo ""
echo "════════════════════════════════════════════════════════"
echo "  FIREWALL STATUS — $(hostname) — $(date)"
echo "════════════════════════════════════════════════════════"
echo ""
echo "── Interfaces ──────────────────────────────────────────"
ip -brief addr show eth0 eth1 eth2 2>/dev/null
echo ""
echo "── Routage ─────────────────────────────────────────────"
ip route
echo ""
echo "── Règles FORWARD ──────────────────────────────────────"
iptables -L FORWARD -v -n --line-numbers
echo ""
echo "── NAT (POSTROUTING) ───────────────────────────────────"
iptables -t nat -L POSTROUTING -v -n
echo ""
echo "── NAT (PREROUTING / DNAT) ─────────────────────────────"
iptables -t nat -L PREROUTING -v -n
echo ""
echo "── Connexions actives (conntrack) ──────────────────────"
if command -v conntrack &>/dev/null; then
  conntrack -L 2>/dev/null | head -20
else
  cat /proc/net/nf_conntrack 2>/dev/null | head -10 || echo "(conntrack non disponible)"
fi
echo ""
echo "── Derniers événements firewall ────────────────────────"
grep "\[FW-" /var/log/syslog 2>/dev/null | tail -15 \
  || journalctl -k --no-pager 2>/dev/null | grep "\[FW-" | tail -15 \
  || echo "(aucun événement récent)"
echo ""
FWSTATUS
chmod +x /usr/local/bin/fw-status

# ── 9. Script de test de connectivité ────────────────────────
cat > /usr/local/bin/fw-test << 'FWTEST'
#!/bin/bash
# Teste la connectivité entre les zones
echo ""
echo "════════════════════════════════════════════════════════"
echo "  TESTS DE CONNECTIVITÉ — Firewall Zones"
echo "════════════════════════════════════════════════════════"
echo ""

pass() { echo -e "\033[32m[✔ PASS]\033[0m $1"; }
fail() { echo -e "\033[31m[✘ FAIL]\033[0m $1"; }
info() { echo -e "\033[34m[→]\033[0m $1"; }

info "Test 1 : Gateway → Internet (WAN)"
curl -s --max-time 3 http://example.com > /dev/null && pass "WAN → Internet OK" || fail "WAN → Internet FAIL"

info "Test 2 : Ping VM2 (DMZ — 192.168.100.10)"
ping -c2 -W2 192.168.100.10 > /dev/null 2>&1 && pass "Gateway → DMZ OK" || fail "Gateway → DMZ FAIL"

info "Test 3 : Ping VM3 (LAN — 192.168.10.10)"
ping -c2 -W2 192.168.10.10 > /dev/null 2>&1 && pass "Gateway → LAN OK" || fail "Gateway → LAN FAIL"

info "Test 4 : Port 80 sur VM2 Web"
curl -s --max-time 3 http://192.168.100.10 > /dev/null && pass "HTTP → VM2 OK" || fail "HTTP → VM2 FAIL"

info "Test 5 : Port 3306 MySQL sur VM3"
(echo > /dev/tcp/192.168.10.10/3306) 2>/dev/null && pass "MySQL port 3306 ouvert" || fail "MySQL port 3306 fermé (normal depuis gateway)"

echo ""
FWTEST
chmod +x /usr/local/bin/fw-test

log "Scripts utilitaires créés : fw-status | fw-test"

# ── 10. Résumé final ─────────────────────────────────────────
echo ""
echo "================================================================"
echo "  ✅ VM1 — Firewall configuré avec succès !"
echo "================================================================"
echo ""
echo "  Zones :"
echo "    WAN (eth0) → NAT + accès Internet"
echo "    LAN (eth1) → 192.168.10.0/24 (réseau privé)"
echo "    DMZ (eth2) → 192.168.100.0/24 (zone web)"
echo ""
echo "  Règles actives :"
echo "    ✔ LAN → Internet    : AUTORISÉ (HTTP/HTTPS)"
echo "    ✔ LAN → DMZ         : AUTORISÉ (port 80 uniquement)"
echo "    ✔ DMZ → Internet    : AUTORISÉ (HTTP/HTTPS/DNS)"
echo "    ✔ DMZ → LAN MySQL   : AUTORISÉ (port 3306 vers DB)"
echo "    ✗ DMZ → LAN (reste) : BLOQUÉ + LOGGÉ"
echo "    ✗ WAN → LAN         : BLOQUÉ + LOGGÉ"
echo "    ✔ WAN → DMZ         : AUTORISÉ (port 80/443 — DNAT)"
echo ""
echo "  Commandes utiles :"
echo "    fw-status   — état complet du firewall"
echo "    fw-test     — tests de connectivité inter-zones"
echo "    cat /var/log/firewall/dropped.log — paquets bloqués"
echo ""
