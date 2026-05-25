#!/bin/bash
set -e
sudo sed -i 's|"127.0.0.1:3100:3100"|"0.0.0.0:3100:3100"|' /opt/monitor/docker-compose.yml
grep '3100' /opt/monitor/docker-compose.yml
cd /opt/monitor
sudo docker compose up -d loki
sleep 5
sudo ss -tlnp | grep 3100
echo "--- promtail retry from kodik-verify ---"
echo "(check from kodik-verify side)"
