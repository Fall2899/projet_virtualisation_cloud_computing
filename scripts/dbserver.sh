#!/bin/bash
# ================================================================
#  VM3 — Serveur Base de Données
#  Rôle   : MySQL 8.0 — accessible depuis le LAN uniquement
#  Réseau : LAN — 192.168.10.10
#  Sécurité : bind sur LAN, utilisateur restreint, audit log
# ================================================================

set -e

GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

echo ""
echo "================================================================"
echo "  VM3 — Serveur MySQL — Provisionnement"
echo "================================================================"
echo ""

# ── 1. Installation MySQL ────────────────────────────────────
info "Installation de MySQL 8.0..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y mysql-server net-tools curl
log "MySQL installé."

# ── 2. Bind MySQL sur l'interface LAN uniquement ─────────────
info "Configuration de MySQL (bind sur LAN)..."
MYCNF="/etc/mysql/mysql.conf.d/mysqld.cnf"

# bind-address : écoute seulement sur le LAN (pas sur 0.0.0.0)
sed -i "s/^bind-address\s*=.*/bind-address = 192.168.10.10/" $MYCNF

# Activer le log général et d'erreurs (style audit pfSense)
cat >> $MYCNF << 'MYSQLCNF'

# ── Sécurité & Performance ──────────────────────────────────
max_connections        = 100
connect_timeout        = 5
wait_timeout           = 600
max_allowed_packet     = 16M
thread_cache_size      = 128

# ── Logs ────────────────────────────────────────────────────
general_log            = 1
general_log_file       = /var/log/mysql/general.log
log_error              = /var/log/mysql/error.log
slow_query_log         = 1
slow_query_log_file    = /var/log/mysql/slow.log
long_query_time        = 2
MYSQLCNF

systemctl restart mysql
log "MySQL redémarré — bind sur 192.168.10.10:3306"

# ── 3. Route persistante vers la DMZ ─────────────────────────
info "Route vers la DMZ (192.168.100.0/24 via gateway)..."
ip route add 192.168.100.0/24 via 192.168.10.1 dev enp0s8 || true

cat > /etc/netplan/99-routes.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    enp0s8:
      routes:
        - to: 192.168.100.0/24
          via: 192.168.10.1
NETPLAN
netplan apply 2>/dev/null || true
log "Route DMZ configurée."

# ── 4. Initialisation de la base de données ──────────────────
info "Initialisation de la base appdb..."
mysql -u root << 'SQL'

-- ── Base de données principale ──────────────────────────────
CREATE DATABASE IF NOT EXISTS appdb
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

-- ── Utilisateur pour le serveur web (DMZ) ───────────────────
-- Accès limité depuis le réseau DMZ uniquement
DROP USER IF EXISTS 'webuser'@'192.168.100.10';
CREATE USER 'webuser'@'192.168.100.10'
  IDENTIFIED WITH mysql_native_password BY 'WebPass123!'
  PASSWORD EXPIRE NEVER
  FAILED_LOGIN_ATTEMPTS 5
  PASSWORD_LOCK_TIME 1;

-- Droits minimaux (principe du moindre privilège)
GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'webuser'@'192.168.100.10';

-- ── Utilisateur admin (local uniquement) ─────────────────────
DROP USER IF EXISTS 'admin'@'localhost';
CREATE USER 'admin'@'localhost'
  IDENTIFIED BY 'AdminPass123!';
GRANT ALL PRIVILEGES ON appdb.* TO 'admin'@'localhost';

FLUSH PRIVILEGES;

-- ── Schéma de la base ────────────────────────────────────────
USE appdb;

CREATE TABLE IF NOT EXISTS users (
  id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  username   VARCHAR(50)  NOT NULL UNIQUE,
  email      VARCHAR(100) NOT NULL,
  role       ENUM('admin','user','moderator') NOT NULL DEFAULT 'user',
  active     TINYINT(1)   NOT NULL DEFAULT 1,
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_role (role),
  INDEX idx_active (active)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS logs (
  id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id    INT UNSIGNED,
  action     VARCHAR(100) NOT NULL,
  ip_address VARCHAR(45),
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL,
  INDEX idx_created (created_at)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS settings (
  id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  `key`      VARCHAR(100) NOT NULL UNIQUE,
  value      TEXT,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ── Données d'exemple ────────────────────────────────────────
INSERT IGNORE INTO users (username, email, role) VALUES
  ('alice',   'alice@example.com',   'admin'),
  ('bob',     'bob@example.com',     'user'),
  ('charlie', 'charlie@example.com', 'user'),
  ('diana',   'diana@example.com',   'moderator');

INSERT IGNORE INTO settings (`key`, value) VALUES
  ('app_name',    'Projet 3-Tiers'),
  ('app_version', '1.0.0'),
  ('env',         'production');

INSERT IGNORE INTO logs (user_id, action, ip_address) VALUES
  (1, 'LOGIN',          '192.168.100.10'),
  (1, 'CREATE_USER',    '192.168.100.10'),
  (2, 'LOGIN',          '192.168.100.10');

SQL

log "Base appdb initialisée (tables: users, logs, settings)."

# ── 5. Script de monitoring MySQL ────────────────────────────
cat > /usr/local/bin/db-status << 'DBSTATUS'
#!/bin/bash
echo ""
echo "════════════════════════════════════════════"
echo "  MySQL STATUS — $(hostname) — $(date)"
echo "════════════════════════════════════════════"
echo ""
echo "── Service ─────────────────────────────────"
systemctl is-active mysql && echo "MySQL : ACTIF" || echo "MySQL : INACTIF"
echo ""
echo "── Écoute réseau ───────────────────────────"
ss -tlnp | grep 3306
echo ""
echo "── Base de données ─────────────────────────"
mysql -u admin -pAdminPass123! -e "
  SELECT TABLE_NAME, TABLE_ROWS, ENGINE
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA='appdb';
" 2>/dev/null
echo ""
echo "── Utilisateurs ────────────────────────────"
mysql -u admin -pAdminPass123! appdb -e "SELECT id, username, email, role FROM users;" 2>/dev/null
echo ""
echo "── Logs récents ────────────────────────────"
mysql -u admin -pAdminPass123! appdb \
  -e "SELECT l.id, u.username, l.action, l.ip_address, l.created_at FROM logs l LEFT JOIN users u ON l.user_id=u.id ORDER BY l.created_at DESC LIMIT 10;" 2>/dev/null
echo ""
DBSTATUS
chmod +x /usr/local/bin/db-status

# ── 6. Résumé ────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  ✅ VM3 — Serveur MySQL configuré avec succès !"
echo "================================================================"
echo "  IP LAN   : 192.168.10.10"
echo "  Port     : 3306 (bind LAN uniquement)"
echo "  Base     : appdb"
echo ""
echo "  Utilisateurs MySQL :"
echo "    webuser@192.168.100.10  → SELECT/INSERT/UPDATE/DELETE sur appdb"
echo "    admin@localhost         → ALL PRIVILEGES sur appdb"
echo ""
echo "  Commandes utiles :"
echo "    db-status                                   → état complet"
echo "    mysql -u admin -pAdminPass123! appdb        → console MySQL"
echo "    tail -f /var/log/mysql/general.log          → audit des requêtes"
echo ""
