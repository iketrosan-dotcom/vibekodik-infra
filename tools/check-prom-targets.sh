#!/bin/bash
echo "=== Prometheus targets ==="
curl -fsS http://127.0.0.1:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | "\(.labels.host // "-")\t\(.labels.job // "-")\t\(.health)\t\(.lastError // "")"' \
  2>/dev/null | column -ts $'\t'
echo
echo "=== Loki: log lines from relayer-01 (last hour) ==="
curl -fsG http://127.0.0.1:3100/loki/api/v1/query \
  --data-urlencode 'query=count_over_time({host="relayer-01"}[1h])' \
  2>/dev/null | jq -r '.data.result[0].value[1] // "0"'
