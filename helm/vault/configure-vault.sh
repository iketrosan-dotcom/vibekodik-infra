#!/usr/bin/env bash
# ==============================================================================
# Пост-init настройка Vault: auth-методы (kubernetes + OIDC/Keycloak), KV, политики.
# Запускать ПОСЛЕ `vault operator init` (auto-unseal через KMS → unseal не нужен)
# и логина root-токеном.
#
# Предпосылки:
#   export VAULT_ADDR=https://vault.kodik.ru
#   vault login <root-token-из-operator-init>
#   Keycloak уже поднят (realm kodik, client 'vault' создан в realm-import).
#
# Запуск:  bash configure-vault.sh
# ==============================================================================
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-https://sso.kodik.ru}"
REALM="${REALM:-kodik}"
VAULT_OIDC_CLIENT_ID="${VAULT_OIDC_CLIENT_ID:-vault}"
# Секрет клиента vault из Keycloak (Clients → vault → Credentials).
VAULT_OIDC_CLIENT_SECRET="${VAULT_OIDC_CLIENT_SECRET:?set VAULT_OIDC_CLIENT_SECRET}"

echo ">> KV v2 secrets engine на пути kv/"
vault secrets enable -path=kv -version=2 kv 2>/dev/null || echo "   (уже включён)"

echo ">> Политики"
# admin — полный доступ (для платформенной команды).
vault policy write kodik-admin - <<'EOF'
path "*" { capabilities = ["create","read","update","delete","list","sudo"] }
EOF

# reader приложений — читают только свой префикс kv/data/apps/<service>.
vault policy write app-reader - <<'EOF'
path "kv/data/apps/*"     { capabilities = ["read","list"] }
path "kv/metadata/apps/*" { capabilities = ["read","list"] }
EOF

echo ">> Kubernetes auth — поды получают Vault-токен по ServiceAccount JWT"
vault auth enable kubernetes 2>/dev/null || echo "   (уже включён)"
# Внутри пода Vault берёт kube API из env; адрес/CA — из service-account.
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"

# Роль: SA 'app' в ns 'apps' → политика app-reader.
vault write auth/kubernetes/role/apps \
  bound_service_account_names="*" \
  bound_service_account_namespaces="apps" \
  policy="app-reader" \
  ttl="1h"

echo ">> OIDC auth через Keycloak (SSO для людей в UI)"
vault auth enable oidc 2>/dev/null || echo "   (уже включён)"
vault write auth/oidc/config \
  oidc_discovery_url="${KEYCLOAK_URL}/realms/${REALM}" \
  oidc_client_id="${VAULT_OIDC_CLIENT_ID}" \
  oidc_client_secret="${VAULT_OIDC_CLIENT_SECRET}" \
  default_role="sso"

# Роль sso: callback'и для CLI и UI; маппинг groups → policies.
vault write auth/oidc/role/sso \
  user_claim="sub" \
  allowed_redirect_uris="https://vault.kodik.ru/ui/vault/auth/oidc/oidc/callback" \
  allowed_redirect_uris="https://vault.kodik.ru/oidc/callback" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback" \
  groups_claim="groups" \
  oidc_scopes="groups" \
  token_policies="app-reader"

# Маппинг группы Keycloak 'platform-admins' → политика kodik-admin.
vault write identity/group name="platform-admins" type="external" \
  policies="kodik-admin"
echo ">> Готово. Проверка: vault login -method=oidc role=sso"
