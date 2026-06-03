# Kodik K8s — Helm / манифесты

Слой поверх terraform-каркаса (`../terraform`). Поднимает платформу и сервисы в
кластере `kodik-prod`. Полный пошаговый прогон — в
[`../vault-keycloak-apps-runbook.md`](../vault-keycloak-apps-runbook.md).

```
helm/
├── bootstrap/        # платформенные addon'ы (ставить ПЕРВЫМИ, по порядку)
│   ├── 00-namespaces.yaml
│   ├── external-secrets-values.yaml        + clustersecretstore-lockbox.yaml
│   ├── cert-manager-values.yaml            + clusterissuer-letsencrypt.yaml
│   ├── ingress-nginx-values.yaml
│   └── kube-prometheus-stack-values.yaml
├── vault/            # HashiCorp Vault: HA + PostgreSQL storage + YC KMS auto-unseal
│   ├── values-vault.yaml
│   ├── ingress-vault.yaml
│   └── configure-vault.sh   # auth (k8s + OIDC/Keycloak) + политики
├── keycloak/         # SSO через официальный Keycloak Operator
│   ├── README.md
│   ├── externalsecret-keycloak-db.yaml
│   ├── keycloak-cr.yaml  + ingress-keycloak.yaml  + realmimport-kodik.yaml
└── apps/             # прикладные сервисы (один generic-чарт, per-service values)
    ├── charts/app/   # Deployment+Service+Ingress+HPA+ExternalSecret+SA
    ├── kodikrouter-api.values.yaml
    ├── kodikrouter-frontend.values.yaml
    ├── kodikdetect.values.yaml
    └── kodik-hackathon.values.yaml
```

## Порядок (кратко)

1. terraform apply (см. `../bootstrap-k8s-runbook.md`) → кластер + PG + KMS + Lockbox.
2. Ротация паролей MDB → заливка Lockbox (vault/keycloak/app-секреты).
3. bootstrap addon'ы + ClusterSecretStore + ClusterIssuer.
4. DNS: vault/sso/api/... → IP NLB ingress-nginx.
5. PostgreSQL: создать таблицы Vault. Vault install → init → configure.
6. Keycloak operator → CR → realm. Связать Vault OIDC ↔ Keycloak.
7. Apps: `helm upgrade --install` каждого сервиса.

`__PLACEHOLDER__` в манифестах подставляются из `terraform output` — см. runbook.
