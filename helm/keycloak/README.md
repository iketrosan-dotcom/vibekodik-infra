# Keycloak (официальный оператор) — SSO для Kodik

Bitnami-чарт с 29.08.2025 за платной подпиской → используем **официальный
Keycloak Operator** (бесплатный, declarative realm через CR).

## Порядок установки

Предпосылки: кластер готов, ESO + ClusterSecretStore `yc-lockbox` работают,
ingress-nginx + cert-manager подняты, Managed PostgreSQL с базой `keycloak` есть,
Lockbox-секрет `keycloak` залит (username/password/admin-username/admin-password).

```bash
# 1. CRD + оператор (версию сверить с актуальной на keycloak.org/operator).
KC_VER=26.0.5   # пример; взять текущую
kubectl apply -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KC_VER}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml"
kubectl apply -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KC_VER}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml"
kubectl apply -n keycloak -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KC_VER}/kubernetes/kubernetes.yml"

# 2. Секреты БД/админа (ESO → Lockbox). Сначала подставь LOCKBOX id'шник:
#    terraform output -json lockbox_secret_ids  → значение для ключа "keycloak"
#    замени __LOCKBOX_KEYCLOAK_SECRET_ID__ в externalsecret-keycloak-db.yaml
kubectl apply -f externalsecret-keycloak-db.yaml
kubectl -n keycloak get secret keycloak-db keycloak-bootstrap-admin   # должны появиться

# 3. Keycloak instance. Подставь __PG_FQDN__ (terraform output postgresql_fqdn).
kubectl apply -f keycloak-cr.yaml
kubectl -n keycloak get keycloak kodik -w   # ждём Ready

# 4. Ingress (sso.kodik.ru). DNS A-запись → IP NLB ingress-nginx должна существовать.
kubectl apply -f ingress-keycloak.yaml

# 5. Realm + клиенты. Перед apply задай секреты клиентов (или потом в UI).
kubectl apply -f realmimport-kodik.yaml
kubectl -n keycloak get keycloakrealmimport kodik -w   # ждём Done
```

## После импорта

1. Зайди в `https://sso.kodik.ru/admin` под bootstrap-админом.
2. Clients → `vault` → Credentials → забери/перегенери secret → положи в Lockbox/Vault
   (`VAULT_OIDC_CLIENT_SECRET` для `configure-vault.sh`).
3. Clients → `grafana` → Credentials → secret → в Lockbox-секрет для Grafana
   (env `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`).
4. Создай пользователей, добавь в группу `platform-admins` (→ Vault `kodik-admin`).

## Заметки / хардненинг

- **TLS до PG**: сейчас `sslmode=require` (шифрование без проверки CA). Для
  `verify-full` смонтируй YC CA в поды через `spec.unsupported.podTemplate` (volume
  с CA.pem) и поменяй URL на `sslmode=verify-full&sslrootcert=...`.
- **HA**: `instances: 2` — Keycloak кластеризуется через Infinispan (JGroups
  DNS_PING внутри namespace). PostgreSQL — единая точка; см. follow-up по HA-PG.
- Версию оператора (`KC_VER`) держи в синхроне с образом; major-апгрейды Keycloak
  иногда требуют миграции realm — читай release notes.
