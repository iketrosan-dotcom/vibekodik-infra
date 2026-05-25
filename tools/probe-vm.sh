#!/bin/bash
# read-only probe — собираем состояние VM для планирования observability
set +e
echo "===== HOST: $(hostname) ====="
echo "--- uname ---"
uname -srm
echo "--- os ---"
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown"
echo "--- uptime ---"
uptime
echo "--- mem ---"
free -h
echo "--- disk ---"
df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs 2>/dev/null | head -10
echo "--- top 10 running services ---"
systemctl list-units --state=running --type=service --no-pager --plain --no-legend 2>/dev/null | awk '{print $1}' | sort | head -15
echo "--- listening sockets (observability ports) ---"
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -E ':(9100|9080|9090|9093|3100|3000|9091|9113|9115|9256|9419)\b' || echo 'none'
echo "--- existing prometheus/grafana/loki ---"
which prometheus node_exporter promtail grafana-server loki alertmanager 2>/dev/null || true
ls /etc/systemd/system/ 2>/dev/null | grep -iE 'prom|node_exp|promtail|loki|grafana|alertm' || echo 'no observability units'
echo "--- journald ---"
journalctl --disk-usage 2>/dev/null | head -1
echo "--- nginx logs ---"
ls -la /var/log/nginx/ 2>/dev/null | head -5 || echo 'no nginx'
echo "===== END ====="
