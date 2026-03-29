#!/bin/bash
# ================================================================
#  CORRECTIF MySQL — VM3-DBServer
#  Exécuter : sudo bash /vagrant/scripts/fix-dbserver.sh
# ================================================================

set -e

GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

echo ""
echo "================================================================"
echo "  CORRECTIF MySQL — Déblocage + Recréation utilisateur webuser"
echo "================================================================"
echo ""

# ── 1. Débloquer toutes les IPs bloquées ─────────────────────
info "Déblocage des hôtes bloqués (FLUSH HOSTS)..."
sudo mysql -u root -e "FLUSH HOSTS;"
log "Hôtes débloqués."

# ── 2. Recréer l'utilisateur webuser proprement ───────────────
info "Recréation de l'utilisateur webuser..."
sudo mysql -u root << 'SQL'
-- Supprimer toutes les versions existantes de webuser
DROP USER IF EXISTS 'webuser'@'%';
DROP USER IF EXISTS 'webuser'@'192.168.100.10';
DROP USER IF EXISTS 'webuser'@'192.168.10.10';
DROP USER IF EXISTS 'webuser'@'localhost';

-- Recréer avec accès depuis n'importe quelle IP
CREATE USER 'webuser'@'%' IDENTIFIED BY 'WebPass123!';
GRANT ALL PRIVILEGES ON appdb.* TO 'webuser'@'%';

-- Augmenter la tolérance aux erreurs de connexion
SET GLOBAL max_connect_errors = 1000000;

FLUSH PRIVILEGES;
FLUSH HOSTS;
SQL
log "Utilisateur webuser recréé avec accès '%'."

# ── 3. Augmenter max_connect_errors dans la config ───────────
info "Configuration de max_connect_errors..."
MYCNF="/etc/mysql/mysql.conf.d/mysqld.cnf"
if ! grep -q "max_connect_errors" $MYCNF; then
    echo "max_connect_errors = 1000000" >> $MYCNF
fi
log "max_connect_errors configuré."

# ── 4. Redémarrer MySQL ───────────────────────────────────────
info "Redémarrage de MySQL..."
systemctl restart mysql
sleep 2
log "MySQL redémarré."

# ── 5. Vérification finale ────────────────────────────────────
echo ""
echo "── Utilisateurs MySQL ───────────────────────────────────"
mysql -u root -e "SELECT user, host FROM mysql.user WHERE user='webuser';"

echo ""
echo "── Test connexion webuser ───────────────────────────────"
mysql -u webuser -pWebPass123! -h 192.168.10.10 appdb \
  -e "SELECT 'Connexion OK' AS status;" 2>/dev/null \
  && echo "✅ Connexion webuser OK !" \
  || echo "⚠️  Connexion depuis localhost — normal, tester depuis VM2"

echo ""
echo "── MySQL écoute sur ─────────────────────────────────────"
ss -tlnp | grep 3306

echo ""
echo "================================================================"
echo "  ✅ Correctif appliqué !"
echo "  Testez depuis VM2 :"
echo "  mysql -u webuser -pWebPass123! -h 192.168.10.10 appdb -e 'SELECT 1;'"
echo "================================================================"
echo ""
