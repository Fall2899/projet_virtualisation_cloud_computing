#!/bin/bash
# ================================================================
#  VM2 — Serveur Web
#  Rôle   : Nginx (reverse proxy) + Node.js (application Express)
#  Réseau : DMZ — 192.168.100.10
#  Route  : vers LAN (DB) via gateway 192.168.100.1
# ================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

echo ""
echo "================================================================"
echo "  VM2 — Serveur Web (Nginx + Node.js) — Provisionnement"
echo "================================================================"
echo ""

# ── 1. Mise à jour ───────────────────────────────────────────
info "Mise à jour des paquets..."
apt-get update -qq
apt-get install -y nginx curl git net-tools \
                   mysql-client \
                   mariadb-client
log "Paquets de base installés (nginx, mysql-client, mariadb-client)."

# ── 2. Node.js 20 LTS ────────────────────────────────────────
info "Installation de Node.js 20 LTS..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
apt-get install -y nodejs
log "Node.js $(node -v) — npm $(npm -v)"

# ── 3. Route persistante vers le LAN (DB via gateway) ────────
info "Ajout de la route vers le LAN (192.168.10.0/24)..."
ip route add 192.168.10.0/24 via 192.168.100.1 dev enp0s8 || true

# Persistance via /etc/netplan (Ubuntu 22.04)
cat > /etc/netplan/99-routes.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    enp0s8:
      routes:
        - to: 192.168.10.0/24
          via: 192.168.100.1
NETPLAN
netplan apply 2>/dev/null || true
log "Route LAN configurée : 192.168.10.0/24 via 192.168.100.1"

# ── 4. Configuration clients MySQL / MariaDB ─────────────────
info "Configuration des clients MySQL et MariaDB..."

# Fichier de configuration pour l'utilisateur vagrant
# Permet de se connecter sans retaper les identifiants
cat > /home/vagrant/.my.cnf << 'MYCNF'
[client]
host     = 192.168.10.10
port     = 3306
user     = webuser
password = WebPass123!
database = appdb

[mysql]
host     = 192.168.10.10
port     = 3306
user     = webuser
password = WebPass123!
database = appdb
prompt   = "VM2-web [\\d]> "

[mysqldump]
host     = 192.168.10.10
port     = 3306
user     = webuser
password = WebPass123!
MYCNF
chmod 600 /home/vagrant/.my.cnf
chown vagrant:vagrant /home/vagrant/.my.cnf

# Même config pour root
cp /home/vagrant/.my.cnf /root/.my.cnf
chmod 600 /root/.my.cnf

# Script utilitaire : connexion rapide à la DB
cat > /usr/local/bin/db-connect << 'DBCONN'
#!/bin/bash
# Connexion rapide à MySQL depuis VM2
echo "Connexion à MySQL — VM3 (192.168.10.10)..."
mysql --host=192.168.10.10 --port=3306 \
      --user=webuser --password=WebPass123! \
      appdb "$@"
DBCONN
chmod +x /usr/local/bin/db-connect

# Script utilitaire : tester la connexion DB
cat > /usr/local/bin/db-test << 'DBTEST'
#!/bin/bash
echo "════════════════════════════════════════════"
echo "  Test connexion DB depuis VM2 (DMZ)"
echo "════════════════════════════════════════════"
echo ""

# Test MySQL client
echo "→ Test mysql client..."
mysql --host=192.168.10.10 --port=3306 \
      --user=webuser --password=WebPass123! \
      --connect-timeout=5 \
      appdb -e "SELECT 'MySQL OK' AS statut, VERSION() AS version;" 2>/dev/null \
  && echo "✅ MySQL client : connexion OK" \
  || echo "❌ MySQL client : connexion FAIL"

echo ""

# Test mariadb client
echo "→ Test mariadb client..."
mariadb --host=192.168.10.10 --port=3306 \
        --user=webuser --password=WebPass123! \
        --connect-timeout=5 \
        appdb -e "SELECT 'MariaDB client OK' AS statut;" 2>/dev/null \
  && echo "✅ MariaDB client : connexion OK" \
  || echo "❌ MariaDB client : connexion FAIL"

echo ""

# Test port réseau
echo "→ Test port 3306..."
nc -zv -w3 192.168.10.10 3306 2>/dev/null \
  && echo "✅ Port 3306 : accessible" \
  || echo "❌ Port 3306 : inaccessible"

echo ""
echo "  Commandes utiles :"
echo "    db-connect          → console MySQL interactive"
echo "    mysql               → utilise ~/.my.cnf automatiquement"
echo "    mariadb             → idem avec client MariaDB"
DBTEST
chmod +x /usr/local/bin/db-test

log "Clients MySQL et MariaDB configurés."
log "Commandes disponibles : db-connect | db-test"

# ── 3b. Test connexion MySQL depuis VM2 ──────────────────────
info "Test de connexion MySQL vers VM3 (192.168.10.10)..."
sleep 2
mysql -u webuser -pWebPass123! -h 192.168.10.10 appdb \
  -e "SELECT 'Connexion MySQL OK' AS status;" 2>/dev/null \
  && log "Client MySQL connecté à VM3 avec succès." \
  || warn "MySQL non joignable pour l'instant — normal si VM3 n'est pas encore prête."

# ── 4. Application Node.js ───────────────────────────────────
APP_DIR="/opt/webapp"
mkdir -p $APP_DIR

info "Création de l'application Node.js..."

cat > $APP_DIR/package.json << 'EOF'
{
  "name": "webapp-3tiers",
  "version": "1.0.0",
  "description": "Application 3-tiers — Projet Fin de Module",
  "main": "app.js",
  "scripts": { "start": "node app.js" },
  "dependencies": {
    "express": "^4.18.2",
    "mysql2": "^3.6.0",
    "morgan": "^1.10.0"
  }
}
EOF

cat > $APP_DIR/app.js << 'APPJS'
'use strict';

const express = require('express');
const mysql   = require('mysql2/promise');
const morgan  = require('morgan');
const fs      = require('fs');
const path    = require('path');

const app  = express();
const PORT = 3000;

// ── Logging des requêtes HTTP ────────────────────────────────
const logStream = fs.createWriteStream(
  path.join('/var/log', 'webapp_access.log'), { flags: 'a' }
);
app.use(morgan('combined', { stream: logStream }));
app.use(morgan('dev'));
app.use(express.json());

// ── Pool de connexions MySQL ─────────────────────────────────
const DB_CONFIG = {
  host            : process.env.DB_HOST || '192.168.10.10',
  user            : process.env.DB_USER || 'webuser',
  password        : process.env.DB_PASS || 'WebPass123!',
  database        : process.env.DB_NAME || 'appdb',
  waitForConnections: true,
  connectionLimit : 10,
  connectTimeout  : 5000,
};

let pool = null;

async function initDB() {
  try {
    pool = mysql.createPool(DB_CONFIG);
    await pool.query('SELECT 1');
    console.log(`✅ MySQL connecté → ${DB_CONFIG.host}:3306`);
  } catch (err) {
    console.error(`⚠️  MySQL non disponible : ${err.message}`);
    pool = null;
  }
}

// ── Routes ───────────────────────────────────────────────────

// Page d'accueil — aucune info sur la DB
app.get('/', async (req, res) => {
  // La DB est utilisée en arrière-plan (comptage membres)
  // mais l'utilisateur ne voit aucune info sur la DB
  let memberCount = 0;
  try {
    if (pool) {
      const [rows] = await pool.query('SELECT COUNT(*) AS total FROM users');
      memberCount = rows[0].total;
    }
  } catch (err) { /* silencieux — l'utilisateur ne sait pas */ }

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.send(`<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Projet 3-Tiers | Vagrant + VirtualBox</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:'Segoe UI',Arial,sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh;padding:40px 20px}
    .container{max-width:860px;margin:0 auto}
    h1{font-size:2rem;color:#38bdf8;margin-bottom:8px}
    .subtitle{color:#94a3b8;margin-bottom:32px;font-size:.95rem}
    .badge{display:inline-block;padding:3px 10px;border-radius:999px;
           background:#1e40af;color:#bfdbfe;font-size:.75rem;margin-left:8px;vertical-align:middle}
    .card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:24px;margin-bottom:20px}
    .card h2{color:#7dd3fc;font-size:1rem;margin-bottom:16px;text-transform:uppercase;letter-spacing:.05em}
    table{width:100%;border-collapse:collapse}
    th,td{padding:10px 14px;text-align:left;border-bottom:1px solid #334155;font-size:.9rem}
    th{color:#94a3b8;font-weight:600}
    td:first-child{color:#38bdf8}
    .dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:6px}
    .green{background:#22c55e}.red{background:#ef4444}
    .stat{display:inline-block;background:#1e293b;border:1px solid #334155;
          border-radius:10px;padding:16px 32px;margin-bottom:24px}
    .stat-number{font-size:2rem;font-weight:700;color:#38bdf8}
    .stat-label{font-size:.85rem;color:#64748b;margin-top:4px}
  </style>
</head>
<body>
<div class="container">
  <h1>Architecture 3-Tiers <span class="badge">Vagrant + VirtualBox</span></h1>
  <p class="subtitle">Projet de Fin de Module — Déploiement d'une architecture réseau virtualisée</p>

  <div class="stat">
    <div class="stat-number">${memberCount}</div>
    <div class="stat-label">membres inscrits</div>
  </div>

  <div class="card">
    <h2>Topologie réseau</h2>
    <table>
      <tr><th>VM</th><th>Rôle</th><th>IP</th><th>Services</th></tr>
      <tr><td>VM1 — Gateway</td><td>Firewall iptables</td><td>192.168.10.1 / 192.168.100.1</td><td>iptables, NAT, routage</td></tr>
      <tr><td>VM2 — Web</td><td>Serveur web</td><td>192.168.100.10</td><td>Nginx, Node.js</td></tr>
      <tr><td>VM3 — DB</td><td>Base de données</td><td>192.168.10.10</td><td>MySQL 8.0</td></tr>
    </table>
  </div>

  <div class="card">
    <h2>Règles Firewall (zones)</h2>
    <table>
      <tr><th>Source</th><th>Destination</th><th>Port</th><th>Action</th></tr>
      <tr><td>LAN</td><td>Internet (WAN)</td><td>*</td><td><span class="dot green"></span>ACCEPT + NAT</td></tr>
      <tr><td>LAN</td><td>DMZ</td><td>80</td><td><span class="dot green"></span>ACCEPT</td></tr>
      <tr><td>DMZ</td><td>LAN (MySQL)</td><td>3306</td><td><span class="dot green"></span>ACCEPT</td></tr>
      <tr><td>DMZ</td><td>LAN (reste)</td><td>*</td><td><span class="dot red"></span>DROP + LOG</td></tr>
      <tr><td>WAN</td><td>DMZ</td><td>80/443</td><td><span class="dot green"></span>ACCEPT (DNAT)</td></tr>
      <tr><td>WAN</td><td>LAN</td><td>*</td><td><span class="dot red"></span>DROP + LOG</td></tr>
    </table>
  </div>
</div>
</body>
</html>`);
});

// Toutes les routes sensibles → 404 discret
// Aucune info sur la DB, les erreurs ou l'infrastructure
app.get('/health', (req, res) => res.status(404).send('Not found'));
app.get('/users',  (req, res) => res.status(404).send('Not found'));
app.get('/info',   (req, res) => res.status(404).send('Not found'));

// 404 générique — aucune info technique
app.use((req, res) => {
  res.status(404).send('Not found');
});

// ── Démarrage ─────────────────────────────────────────────────
initDB().then(() => {
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`🚀 Serveur démarré → http://0.0.0.0:${PORT}`);
  });
});
APPJS

# Installer les dépendances npm
cd $APP_DIR
npm install --silent 2>/dev/null
chown -R www-data:www-data $APP_DIR
log "Application Node.js créée."

# ── 5. Service systemd pour Node.js ─────────────────────────
info "Création du service systemd webapp..."
cat > /etc/systemd/system/webapp.service << 'EOF'
[Unit]
Description=Application Web Node.js — Projet 3-Tiers
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/webapp
ExecStart=/usr/bin/node /opt/webapp/app.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable webapp
systemctl start webapp
log "Service webapp démarré sur le port 3000."

# ── 6. Nginx — reverse proxy ─────────────────────────────────
info "Configuration de Nginx..."
cat > /etc/nginx/sites-available/webapp << 'NGINX'
# Upstream Node.js
upstream nodejs_backend {
    server 127.0.0.1:3000;
    keepalive 32;
}

server {
    listen 80 default_server;
    server_name _;

    # Logs
    access_log /var/log/nginx/webapp_access.log combined;
    error_log  /var/log/nginx/webapp_error.log warn;

    # Timeouts
    proxy_connect_timeout 10s;
    proxy_send_timeout    30s;
    proxy_read_timeout    30s;

    # Headers de sécurité (style pfSense)
    add_header X-Frame-Options       "SAMEORIGIN"   always;
    add_header X-Content-Type-Options "nosniff"      always;
    add_header X-XSS-Protection      "1; mode=block" always;
    add_header Referrer-Policy        "no-referrer"  always;

    # Reverse proxy → Node.js
    location / {
        proxy_pass         http://nodejs_backend;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade     $http_upgrade;
        proxy_set_header   Connection  "upgrade";
        proxy_set_header   Host        $host;
        proxy_set_header   X-Real-IP   $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # Page d'erreur personnalisée
    error_page 502 503 /50x.html;
    location = /50x.html {
        return 200 '<h2>Service temporairement indisponible</h2>';
        add_header Content-Type text/html;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/webapp /etc/nginx/sites-enabled/webapp
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx && systemctl enable nginx
log "Nginx configuré (reverse proxy → port 3000)."

# ── 7. Résumé ────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  ✅ VM2 — Serveur Web configuré avec succès !"
echo "================================================================"
echo "  IP DMZ   : 192.168.100.10"
echo "  Nginx    : port 80 (reverse proxy)"
echo "  Node.js  : port 3000 ($(node -v))"
echo "  DB cible : 192.168.10.10:3306"
echo ""
echo "  Endpoints disponibles :"
echo "    http://192.168.100.10/          → Accueil"
echo "    http://192.168.100.10/health    → Statut DB"
echo "    http://192.168.100.10/users     → Utilisateurs"
echo "    http://192.168.100.10/info      → Infos système"
echo ""
echo "  Depuis l'hôte (port forwarding Vagrant) :"
echo "    http://localhost:8080/"
echo ""
