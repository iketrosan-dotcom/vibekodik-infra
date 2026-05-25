#!/bin/bash
# provision-agent.sh — раскатывает node_exporter + promtail на target VM.
# Запускать на target VM как root/sudo. LOKI_URL переопределяется через env.
#
# Зачем:
#   - node_exporter listen на :9100 — Prometheus на monitor.kodik.ru pull'ит через
#     internal IP. Защищён SG (только из monitor-sg).
#   - promtail тейлит journald + /var/log/nginx/*.log (если есть), push'ит к Loki.
#
# Конкретно собирает:
#   - journald systemd logs (все)
#   - nginx access+error logs (если /var/log/nginx есть)
#   - метаданные хоста (hostname) как label
set -euo pipefail

LOKI_URL="${LOKI_URL:-http://10.128.0.6:3100/loki/api/v1/push}"
NODE_EXPORTER_VERSION="1.8.2"
PROMTAIL_VERSION="3.2.1"
HOSTNAME=$(hostname)

echo "=== provisioning agents on $HOSTNAME → Loki at $LOKI_URL ==="

# Зависимости (curl/tar обычно есть; unzip — не на всех VM по дефолту)
if ! command -v unzip >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip
fi

# UFW: если активен — открыть 9100 от monitor (10.128.0.6) и Loki push from monitor IP
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
  sudo ufw allow from 10.128.0.6 to any port 9100 proto tcp comment 'node_exporter-from-monitor' >/dev/null
fi

# --- node_exporter ---
if ! id node_exp >/dev/null 2>&1; then
  sudo useradd --no-create-home --shell /usr/sbin/nologin --system node_exp
fi

if [ ! -x /usr/local/bin/node_exporter ]; then
  cd /tmp
  curl -sLO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  sudo install -m 0755 -o root -g root \
    "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" \
    /usr/local/bin/node_exporter
  rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"*
fi

sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exp
Group=node_exp
ExecStart=/usr/local/bin/node_exporter \
  --collector.systemd \
  --collector.processes \
  --web.listen-address=:9100
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

# --- promtail ---
if ! id promtail >/dev/null 2>&1; then
  sudo useradd --no-create-home --shell /usr/sbin/nologin --system --groups adm,systemd-journal promtail || \
  sudo useradd --no-create-home --shell /usr/sbin/nologin --system --groups adm promtail
fi

if [ ! -x /usr/local/bin/promtail ]; then
  cd /tmp
  curl -sL -o "promtail.zip" "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"
  unzip -o -q promtail.zip
  sudo install -m 0755 -o root -g root promtail-linux-amd64 /usr/local/bin/promtail
  rm -f promtail.zip promtail-linux-amd64
fi

sudo mkdir -p /etc/promtail /var/lib/promtail

# Промтейл-конфиг: journald всегда, nginx — если есть директория
NGINX_SCRAPE=""
if [ -d /var/log/nginx ]; then
  NGINX_SCRAPE="
  - job_name: nginx-access
    static_configs:
      - targets: [localhost]
        labels:
          job: nginx-access
          host: ${HOSTNAME}
          __path__: /var/log/nginx/access.log
  - job_name: nginx-error
    static_configs:
      - targets: [localhost]
        labels:
          job: nginx-error
          host: ${HOSTNAME}
          __path__: /var/log/nginx/error.log"
fi

sudo tee /etc/promtail/config.yml > /dev/null <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: warn

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: ${LOKI_URL}
    timeout: 10s
    backoff_config:
      min_period: 500ms
      max_period: 5m
      max_retries: 10
    external_labels:
      host: ${HOSTNAME}

scrape_configs:
  - job_name: journal
    journal:
      max_age: 12h
      path: /var/log/journal
      labels:
        job: systemd-journal
        host: ${HOSTNAME}
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
      - source_labels: ['__journal__hostname']
        target_label: hostname
      - source_labels: ['__journal_priority']
        target_label: priority
${NGINX_SCRAPE}
EOF

# nginx логи доступны только www-data:adm. Добавляем promtail в adm.
sudo usermod -aG adm promtail 2>/dev/null || true
# /var/lib/promtail должна быть писабельна promtail
sudo chown -R promtail:promtail /var/lib/promtail

sudo tee /etc/systemd/system/promtail.service > /dev/null <<'UNIT'
[Unit]
Description=Promtail (Loki log shipper)
After=network-online.target
Wants=network-online.target

[Service]
User=promtail
Group=promtail
SupplementaryGroups=adm systemd-journal
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter.service promtail.service

sleep 2
echo "--- status ---"
sudo systemctl is-active node_exporter.service promtail.service
echo "--- node_exporter sample ---"
curl -fsS http://127.0.0.1:9100/metrics | head -3
echo "--- promtail config-check ---"
curl -fsS http://127.0.0.1:9080/ready 2>/dev/null || echo "(promtail ready endpoint may not respond yet)"
echo "=== done on $HOSTNAME ==="
