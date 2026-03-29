# Projet de Fin de Module — Architecture 3-Tiers Virtualisée

> **Titre :** Déploiement d'une architecture réseau 3-tiers avec Vagrant + VirtualBox  
> **Firewall :** iptables avancé (style pfSense — zones WAN / LAN / DMZ)  
> **OS :** Ubuntu 22.04 LTS (jammy64)

---

## 📐 Architecture réseau

```
                    ┌──────────────────────────────────────────────────┐
                    │              Machine Hôte (VirtualBox)            │
                    │                                                  │
                    │   localhost:8080 ──────────────────────────────┐ │
                    └────────────────────────────────────────────────┼─┘
                                                                     │
                         Internet (NAT — eth0)                       │
                                  │                                  │
                    ┌─────────────┴─────────────┐                    │
                    │      VM1 — GATEWAY        │                    │
                    │   Firewall iptables        │                    │
                    │   (style pfSense)          │                    │
                    │                           │                    │
                    │  WAN : eth0 (NAT)         │                    │
                    │  LAN : eth1 192.168.10.1  │                    │
                    │  DMZ : eth2 192.168.100.1 │                    │
                    └──────┬────────────────────┘                    │
                           │                                         │
              ┌────────────┴──────────────┐                         │
              │                           │                         │
    ┌─────────┴──────────┐   ┌────────────┴───────────┐            │
    │   Réseau LAN        │   │   Réseau DMZ           │            │
    │  192.168.10.0/24   │   │  192.168.100.0/24      │            │
    │                    │   │                         │            │
    │  VM3 — DB SERVER   │   │  VM2 — WEB SERVER  ────┼────────────┘
    │  192.168.10.10     │   │  192.168.100.10         │
    │  MySQL 8.0         │   │  Nginx + Node.js        │
    └────────────────────┘   └─────────────────────────┘
```

---

## 🔥 Règles Firewall (iptables — zones style pfSense)

| Source | Destination     | Port       | Action              | Raison                          |
|--------|-----------------|------------|---------------------|---------------------------------|
| LAN    | Internet (WAN)  | *          | ✅ ACCEPT + NAT      | Navigation libre                |
| LAN    | DMZ             | 80         | ✅ ACCEPT            | Accès web interne               |
| DMZ    | LAN (MySQL)     | 3306       | ✅ ACCEPT (→DB seul) | Web → DB                        |
| DMZ    | LAN (reste)     | *          | ❌ DROP + LOG        | Isolation DMZ                   |
| DMZ    | Internet (WAN)  | 80/443/53  | ✅ ACCEPT            | apt, npm, DNS                   |
| WAN    | DMZ             | 80/443     | ✅ ACCEPT + DNAT     | Accès public au site web        |
| WAN    | LAN             | *          | ❌ DROP + LOG        | LAN jamais exposé               |
| *      | Gateway (SSH)   | 22         | ✅ ACCEPT (LAN seul) | Administration                  |

**Protections activées :** SYN flood, paquets invalides, anti-spoofing (rp_filter), rate-limiting ICMP, DSCP QoS

---

## 🚀 Démarrage rapide

### Prérequis

| Outil | Version minimale | Lien |
|-------|-----------------|------|
| VirtualBox | 6.1+ | https://www.virtualbox.org |
| Vagrant | 2.3+ | https://www.vagrantup.com |
| RAM disponible | 3 Go minimum | — |
| Espace disque | 8 Go minimum | — |

### Lancer le projet

```bash
# 1. Cloner le dépôt
git clone https://github.com/<votre-user>/projet-3tiers.git
cd projet-3tiers

# 2. Démarrer les VMs (première fois : ~10–20 min)
vagrant up

# Ou VM par VM (dans cet ordre)
vagrant up gateway
vagrant up dbserver
vagrant up webserver
```

### Vérifier que tout fonctionne

```bash
# Accéder à l'application web
open http://localhost:8080

# Vérifier la connexion DB
curl http://localhost:8080/health

# Liste des utilisateurs
curl http://localhost:8080/users
```

---

## 🖥️ Commandes Vagrant

```bash
vagrant status              # État des 3 VMs
vagrant ssh gateway         # SSH dans VM1
vagrant ssh webserver       # SSH dans VM2
vagrant ssh dbserver        # SSH dans VM3
vagrant halt                # Arrêter les VMs
vagrant reload --provision  # Redémarrer + re-provisionner
vagrant destroy -f          # Supprimer les VMs
```

---

## 🔍 Vérifications manuelles par VM

### VM1 — Firewall

```bash
vagrant ssh gateway

# Voir toutes les règles iptables avec compteurs
sudo iptables -L -v -n --line-numbers

# Règles NAT
sudo iptables -t nat -L -v -n

# Tableau de bord complet du firewall
sudo fw-status

# Test de connectivité inter-zones
sudo fw-test

# Paquets droppés en temps réel
sudo tail -f /var/log/firewall/dropped.log

# Paquets droppés dans le journal système
sudo journalctl -k -f | grep "\[FW-"
```

### VM2 — Serveur Web

```bash
vagrant ssh webserver

# Statut des services
sudo systemctl status nginx
sudo systemctl status webapp

# Logs Node.js
sudo journalctl -u webapp -f

# Logs Nginx
sudo tail -f /var/log/nginx/webapp_access.log

# Test direct Node.js
curl http://localhost:3000/health

# Test via Nginx
curl http://localhost/health
```

### VM3 — MySQL

```bash
vagrant ssh dbserver

# Statut complet de la DB
sudo db-status

# Console MySQL
mysql -u admin -pAdminPass123! appdb

# Requêtes MySQL depuis VM2 (test du firewall DMZ→LAN)
mysql -u webuser -pWebPass123! -h 192.168.10.10 appdb \
  -e "SELECT * FROM users;"

# Audit des requêtes SQL
sudo tail -f /var/log/mysql/general.log
```

---

## 🧪 Tests de sécurité réseau

```bash
# Depuis VM2 (DMZ) — accès LAN non-DB doit être bloqué
vagrant ssh webserver
ping 192.168.10.10           # ICMP bloqué par firewall
curl http://192.168.10.10    # HTTP bloqué (pas de serveur web sur LAN)

# Depuis VM3 (LAN) — accès DMZ doit passer
vagrant ssh dbserver
ping 192.168.100.10          # ICMP bloqué par firewall (retour)
curl http://192.168.100.10   # HTTP autorisé (LAN→DMZ port 80)

# Vérifier les logs de blocage sur VM1
vagrant ssh gateway
sudo grep "\[FW-DROP\]" /var/log/syslog | tail -20
```

---

## 📂 Structure du projet

```
projet-3tiers/
├── Vagrantfile               ← Définition des 3 VMs + réseaux
├── README.md                 ← Ce fichier
└── scripts/
    ├── gateway.sh            ← VM1 : iptables avancé (zones WAN/LAN/DMZ)
    ├── webserver.sh          ← VM2 : Nginx + Node.js + routing DMZ
    └── dbserver.sh           ← VM3 : MySQL 8.0 + sécurité + audit
```

---

## 📋 Parties du projet

| Partie | Description | Implémentation |
|--------|-------------|---------------|
| **Partie 1** — Virtualisation | 3 VMs Ubuntu 22.04 | Vagrant + VirtualBox |
| **Partie 2** — Déploiement services | Web + DB | Nginx, Node.js, MySQL 8.0 |
| **Partie 3** — Réseaux | LAN + DMZ + firewall | iptables (style pfSense) |
| **Partie 4** — GitHub | Versionning | Git + GitHub Actions |

---

## 🔗 Partie 4 — Intégration GitHub

### Initialiser et pousser

```bash
git init
git add .
git commit -m "feat: architecture 3-tiers vagrant+virtualbox+iptables"
git remote add origin https://github.com/<votre-user>/projet-3tiers.git
git push -u origin main
```

### Workflow GitHub Actions (CI)

Créer `.github/workflows/validate.yml` :

```yaml
name: Validate Project Structure

on: [push, pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Vérifier les fichiers requis
        run: |
          test -f Vagrantfile       && echo "✔ Vagrantfile OK"
          test -f scripts/gateway.sh  && echo "✔ gateway.sh OK"
          test -f scripts/webserver.sh && echo "✔ webserver.sh OK"
          test -f scripts/dbserver.sh  && echo "✔ dbserver.sh OK"

      - name: Vérifier la syntaxe bash
        run: |
          bash -n scripts/gateway.sh
          bash -n scripts/webserver.sh
          bash -n scripts/dbserver.sh
          echo "✔ Syntaxe bash valide"

      - name: Vérifier la syntaxe Vagrantfile (Ruby)
        run: ruby -c Vagrantfile && echo "✔ Vagrantfile syntaxe OK"
```

---

## 📊 Tableau récapitulatif des VMs

| VM | Nom VirtualBox | IP(s) | RAM | Services |
|----|----------------|-------|-----|---------|
| VM1 | VM1-Gateway-pfSense-like | 192.168.10.1 / 192.168.100.1 | 512 Mo | iptables, ip_forward, ulogd2 |
| VM2 | VM2-WebServer | 192.168.100.10 | 1 Go | Nginx 1.18, Node.js 18 LTS |
| VM3 | VM3-DBServer | 192.168.10.10 | 1 Go | MySQL 8.0 |
