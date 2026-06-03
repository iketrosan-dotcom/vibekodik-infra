#!/usr/bin/env sh
# ==============================================================================
# Настройка Vault под ESO-доступ приложений (Фаза C2).
# Идемпотентно. Запускать ВНУТРИ активного Vault-пода с root-токеном:
#
#   t=$(jq -r .root_token c:/src/kodik/.secrets/vault-init.json)   # локально
#   kubectl exec -i -n vault vault-0 -- \
#     env VAULT_TOKEN="$t" VAULT_ADDR=http://vault-active.vault.svc:8200 sh -s < vault-eso-setup.sh
#
# Что делает:
#   1. KV v2 на kv/ (переиспользуем; configure-vault.sh мог уже включить).
#   2. Политика app-reader: read только kv/data/apps/* (least privilege).
#   3. Kubernetes auth + config (token-reviewer берётся из SA самого Vault-пода).
#   4. Роль external-secrets: SA external-secrets/external-secrets → app-reader.
#      (Поды приложений в Vault НЕ ходят — читает ESO; роль 'apps' из configure-vault.sh
#       для прямого доступа подов нам не нужна, не трогаем.)
# ==============================================================================
set -e

echo ">> [1/4] KV v2 @ kv/"
vault secrets enable -path=kv -version=2 kv 2>/dev/null && echo "   enabled" || echo "   (уже включён)"

echo ">> [2/4] policy app-reader (read kv/data/apps/*)"
vault policy write app-reader - <<'POL'
path "kv/data/apps/*"     { capabilities = ["read"] }
path "kv/metadata/apps/*" { capabilities = ["read", "list"] }
POL

echo ">> [3/4] kubernetes auth + config"
vault auth enable kubernetes 2>/dev/null && echo "   enabled" || echo "   (уже включён)"
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"

echo ">> [4/4] role external-secrets → app-reader"
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names="external-secrets" \
  bound_service_account_namespaces="external-secrets" \
  token_policies="app-reader" \
  ttl="1h"

echo ">> Готово. Проверка:"
echo "   vault read auth/kubernetes/role/external-secrets"
echo "   vault policy read app-reader"
