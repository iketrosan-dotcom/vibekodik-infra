#!/bin/bash
echo "=== Loki: discovered host labels ==="
curl -sG http://127.0.0.1:3100/loki/api/v1/label/host/values 2>/dev/null | jq -r '.data[]'
echo
echo "=== Loki: journal log count by host (last 5 min) ==="
curl -sG http://127.0.0.1:3100/loki/api/v1/query \
  --data-urlencode 'query=count by (host) (count_over_time({job="systemd-journal"}[5m]))' \
  2>/dev/null | jq -r '.data.result[] | "\(.metric.host): \(.value[1])"'
