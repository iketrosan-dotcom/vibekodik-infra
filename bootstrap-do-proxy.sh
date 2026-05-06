#!/bin/bash
# Bootstrap script для outbound proxy на DigitalOcean (Ubuntu 24.04).
# Применяется к VM Kodik-RevProxy (157.230.120.167) и KodikRouter-RevProxy (64.226.78.10).
#
# Назначение этих VM: outbound forward-proxy для LLM-запросов из RU backend
# (чтобы LLM-провайдеры видели зарубежный IP, а не РФ).
# Маршрут: [user] -> [RU backend] -> [proxy.kodik.ru / proxy.kodikrouter.ru] -> [OpenAI/Anthropic/...]
#
# Что делает этот скрипт (идемпотентно):
#   1. apt update + install: nginx, certbot, python3-certbot-nginx, fail2ban, ufw
#   2. Swap 1 GB (страховка от OOM на 4 GB RAM)
#   3. fail2ban для sshd (порт 22, maxretry=5, ban=1h)
#   4. nginx hardening: server_tokens off
#   5. nginx default site → return 444 (закрыть соединение для чужих Host'ов)
#   6. UFW: разрешено только 22/80/443, остальное deny
#
# НЕ делает (отдельные шаги после bootstrap):
#   - TLS (требует DNS A-записей proxy.kodik.ru / proxy.kodikrouter.ru)
#   - forward-proxy nginx-config с X-Target-URL (требует формата от dev-команды)
#   - Bearer-token auth (требует решения по схеме авторизации)
#   - Whitelist allowed targets (требует списка LLM-провайдеров)
#
# Использование:
#   scp bootstrap-do-proxy.sh root@<DO-IP>:/tmp/
#   ssh root@<DO-IP> 'bash /tmp/bootstrap-do-proxy.sh'

set -e
export DEBIAN_FRONTEND=noninteractive

echo "=== apt update ==="
apt-get update -qq

echo "=== install packages ==="
apt-get install -y -qq nginx certbot python3-certbot-nginx fail2ban ufw

echo "=== swap 1G ==="
if ! swapon --show | grep -q .; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile > /dev/null
  swapon /swapfile
  grep -qF "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

echo "=== fail2ban ==="
cat > /etc/fail2ban/jail.d/custom.local << 'JAIL'
[sshd]
enabled = true
port    = 22
maxretry = 5
findtime = 10m
bantime  = 1h
JAIL
systemctl enable --now fail2ban

echo "=== nginx hardening ==="
cat > /etc/nginx/conf.d/00-hardening.conf << 'CONF'
server_tokens off;
CONF

echo "=== nginx default site -> 444 ==="
cat > /etc/nginx/sites-available/default << 'SITE'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
SITE
nginx -t
systemctl reload nginx

echo "=== ufw ==="
ufw allow 22/tcp comment 'SSH' > /dev/null
ufw allow 80/tcp comment 'HTTP' > /dev/null
ufw allow 443/tcp comment 'HTTPS' > /dev/null
echo "y" | ufw enable > /dev/null 2>&1 || true

echo "=== DONE ==="
echo "uptime: $(uptime -p)"
free -h | grep -E 'Mem|Swap'
