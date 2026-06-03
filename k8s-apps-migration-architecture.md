# Миграция приложений Kodik в `kodik-prod` — аудит + целевая архитектура

**Дата:** 2026-06-03. **Автор:** Claude (для Кристиана).
**Принцип:** не lift-and-shift. Сначала чистая k8s-native архитектура, потом миграция.
**Статус инфры:** кластер `kodik-prod` (1.33, 5 нод) + cert-manager + ESO + ingress-nginx (NLB `81.26.176.194`) + Vault (KMS auto-unseal) + Keycloak + kube-prometheus-stack — **всё LIVE**. Осталось: прикладные сервисы.

---

## 1. Аудит исходных VM (live-инспекция 2026-06-03, не по памяти)

### 1.1 KodikRouter API — `vibekodik-app-01` + `vibekodik-app-02`

| Параметр | Факт |
|---|---|
| Runtime | systemd `kodikrouter-api`, uvicorn `app.main:app --workers 1 --limit-max-requests 5000 --limit-concurrency 64` |
| Env (systemd) | `MALLOC_ARENA_MAX=2`, `MALLOC_TRIM_THRESHOLD_=131072`, `OMP_NUM_THREADS=2`, `MKL_NUM_THREADS=2`, `MemoryHigh=10G`, `MemoryMax=12G`, `Restart=always`, `RestartSec=3`, `TasksMax=512`, `LimitNOFILE=65535` |
| Python | 3.12.3, venv `/opt/vibekodik/api/env` |
| Код | `mike2505/KodikRouterAPI` ветка **main @ `cf95533` (2026-05-26 «fix: balance issue»)** |
| Порт | `0.0.0.0:8000` |
| ML-веса | **2.4 GB** в `/opt/vibekodik/api/anonymizer/`: `gliner-medium-v2.1` + `kodik-detector-epoch4-f1-89` (тянутся из Selectel S3 bucket `kodik`, prefix `anonymizer/`) |
| RSS (workers=1) | **~3.2 GB** в покое (важно для лимитов!) |
| Зависимости | torch 2.11.0, transformers 5.1.0, gliner 0.2.26, accelerate, sentencepiece, fastapi 0.115, sqlalchemy 2.0, openai/anthropic SDK, boto3 |
| Env-ключи (52 шт) | DB_* (HOST/PORT/NAME/USER/PASSWORD + POOL_SIZE/MAX_OVERFLOW/POOL_RECYCLE/POOL_TIMEOUT), REDIS_URL, JWT_*, OPENROUTER_API_KEY, GITHUB_* , GOOGLE_*, OAUTH_REDIRECT_BASE, YOOKASSA_* (LIVE), STRIPE_*, S3_*, SMTP_*, PROXY_URL + PROXY_AUTH_TOKEN, TELEGRAM_BOT_TOKEN/ADMIN_CHAT_ID/API_BASE_URL, MAX_REQUEST_BODY_BYTES, ANALYTICS_COUNT_FROM, CREDITS_MARKUP_PCT, PROVIDER_PRICE_TO_RUB_RATE, APP_ENV/APP_DEBUG |
| VM | 16 vCPU / 32 GB (сильно недогружена — реально нужно ~4 vCPU/8GB на под) |

### 1.2 KodikRouter Frontend — `vibekodik-frontend`

| Параметр | Факт |
|---|---|
| Runtime | systemd `kodikrouter-frontend`, `npm run start`, NODE_ENV=production, PORT=3000, HOSTNAME=0.0.0.0, Restart=on-failure |
| Node | v22.22.2, npm 10.9.7, lock = `package-lock.json` (npm) |
| Код | `mike2505/KodikRouterFront` **main @ `aa1bbc8` (2026-06-01 «40+ → 300+ models»)** ← локальный clone устарел (V1.0.0) |
| Build | **НЕ standalone** (обычный `next build`, `.next/` 26 MB, запускается через `next start` → нужен весь node_modules в рантайме) |
| Env | только `NEXT_PUBLIC_API_URL=https://api.kodikrouter.ru` — **build-time** (запекается в бандл, не рантайм) |
| RSS | ~167 MB. Порт `*:3000` |
| VM | 8 vCPU / 16 GB (избыток — нужно ~250m/512Mi) |

### 1.3 KodikDetect / scan.kodik.ru — `kodik-verify`

| Параметр | Факт |
|---|---|
| Runtime | PM2 `kodik-detect` (online, **16 рестартов** — есть нестабильность), node-интерпретатор |
| Node | v22.22.2 |
| Код | `mike2505/KodikDetect` **main @ `a222b97` (2026-05-25)**, app = `repo/hive-detector` (subdir!) |
| Порт | `*:3000`, nginx TLS впереди (`scan.kodik.ru` → 127.0.0.1:3000) |
| Env | `HIVE_API_KEY`, `SAPLING_API_KEY`, `SAPLING_PUBLIC_KEY` (внешние detector-API, не БД) |
| Build | НЕ standalone |
| VM | 2 vCPU / 4 GB, used 779 MB. **Полностью stateless** (только внешние API) → самый простой |

### 1.4 hackathon / hackathon.kodik.ru — `kodik-hackathon`

| Параметр | Факт |
|---|---|
| Backend | docker `kodik-backend:latest` (FastAPI, **есть Dockerfile** в `/opt/kodik-hackathon/backend/Dockerfile`), `127.0.0.1:8000`, healthy |
| Frontend | next-server `*:3000` **на хосте** (НЕ в docker, не контейнеризован) |
| БД | docker `kodik-db` = **postgres:16-alpine** (volume `kodik_pgdata` — есть данные), `kodik-redis` = redis:7-alpine (оба local-only) |
| Прочее | `system-health-monitor` (alpine) |
| nginx | `hackathon.kodik.ru`: `/api`→8000, `/`→3000 |
| compose | `/opt/kodik-hackathon/backend/docker-compose.yml` + `.override.yml` |
| VM | 2 vCPU / 4 GB. Гибрид: backend в docker, frontend на хосте, своя БД |

### 1.5 Данные — `vibekodik-db`

| Параметр | Факт |
|---|---|
| MySQL | **8.0.46**, БД `kodikrouterapi` = **12.7 GB** (27 таблиц), alembic head `b7e9a3c1f482`, listen `0.0.0.0:3306` |
| Binlogs | отдельный диск `/var/lib/mysql-binlogs` (98G, 5.5G used) |
| Redis | **7.0.15**, всего 3 ключа / 1.04 MB, `allkeys-lru`, `appendonly=no` → **кэш-расходник, мигрировать нечего** |
| VM | 4 vCPU / 16 GB |

### 1.6 Что НЕ мигрирует / решается отдельно

- `vibekodik-lb` (nginx TLS) → заменяется ingress-nginx. **Decommission после cutover всех сервисов.**
- `kodik-ci` (3 self-hosted GH runner) → заменяется **ARC** в кластере. Decommission после.
- `monitor` (Prom+Loki+Grafana docker-compose) → заменён **kube-prometheus-stack** (уже в кластере). Осталось перенести Loki-логи + Telegram-алерты, потом decommission.
- `kodik-hosting` (Docker+Caddy, `*.apps.kodik.ru`) → **остаётся VM** (DinD пользовательских образов не k8s-native, отдельный разговор).
- `relayer-01` → **остаётся** bastion + DO-proxy egress.

---

## 2. Целевая архитектура (k8s-native, не калька с VM)

### 2.1 Namespaces — по продуктам (изоляция + NetworkPolicy + quota)

Вместо одного `apps` — namespace на продукт. Чище для RBAC/quota/сетевых политик:

| Namespace | Сервисы |
|---|---|
| `kodikrouter` | kodikrouter-api, kodikrouter-frontend |
| `kodikdetect` | kodikdetect |
| `hackathon` | hackathon-backend, hackathon-frontend |
| `arc-system` | actions-runner-controller + runner scale sets |

> Меняет текущие values (`-n apps`). Решение зафиксировано: **product-namespaces**.

### 2.2 Секреты — Vault KV v2 + ESO Vault-provider

```
Vault (ns vault, уже live, KMS auto-unseal, внутри HTTP :8200)
  ├── secrets engine: kv-v2 @ mount kv/  (переиспользуем из configure-vault.sh)
  │     kv/apps/kodikrouter-api   → все 52 env (DB/JWT/OpenRouter/OAuth/YooKassa/...)
  │     kv/apps/kodikdetect       → HIVE_API_KEY, SAPLING_*
  │     kv/apps/hackathon         → DB creds + ADMIN_TOKEN
  │     (frontend секретов не требует — NEXT_PUBLIC_* билд-тайм)
  ├── auth: kubernetes — логинится ТОЛЬКО ESO (не сами поды)
  └── policy: app-reader (read kv/data/apps/*) → k8s-role external-secrets (SA external-secrets/external-secrets)

ESO: ClusterSecretStore "vault-kv" (provider vault, http, auth kubernetes, role external-secrets)
  → ExternalSecret <svc>-env (рендерит generic-чарт) тянет kv/apps/<svc> → k8s Secret → envFrom
```

Почему ESO+Vault, а не Vault Agent Injector: ESO уже развёрнут и работает (для Lockbox-секретов keycloak/vault). Добавить ему второй store дешевле, чем тащить injector-sidecar в каждый под (injector в чарте Vault и так `enabled:false`). Поды приложений в Vault **не ходят** — читает ESO. Lockbox остаётся **только** для bootstrap инфры (vault/keycloak), приложения — на Vault.

**Артефакты C2:** [`helm/apps/vault-eso-setup.sh`](helm/apps/vault-eso-setup.sh) (idempotent: kv/ + app-reader + k8s-auth + role external-secrets), [`helm/apps/clustersecretstore-vault.yaml`](helm/apps/clustersecretstore-vault.yaml).

**DB-креды:** в Vault кладём полный коннект к MDB: `DB_HOST=<mdb-mysql-fqdn>`, `DB_PORT=3306`, `DB_USER=kodikrouterapi`, `DB_PASSWORD=<rotated>`, `REDIS_URL=rediss://:<pw>@<mdb-redis-fqdn>:6379/0` (TLS!).

### 2.3 Образы + CI (ARC) — выбрано пользователем

```
actions-runner-controller (ns arc-system)
  ├── RunnerScaleSet kodikrouter-api    → repo mike2505/KodikRouterAPI
  ├── RunnerScaleSet kodikrouter-front  → repo mike2505/KodikRouterFront
  ├── RunnerScaleSet kodikdetect        → repo mike2505/KodikDetect
  └── RunnerScaleSet hackathon          → repo <hackathon repo>

GH Actions workflow (на каждый репо):
  build (docker buildx) → tag dev-<sha> + (на tag) vX.Y.Z → push cr.yandex/crp7738saq8ngg8ad5tm/<svc>
  → (опц.) helm upgrade --install <svc> ./charts/app -f <svc>.values.yaml -n <ns> --set image.tag=<sha>
```

YCR-пуш из раннеров: отдельный SA `ycr-pusher` с ролью `container-registry.images.pusher`, ключ в GH Secret (или Workload Identity). Раннеры тянут образы под node-SA (`container-registry.images.puller` уже есть).

### 2.4 Dockerfile-стратегия (по сервисам)

| Сервис | Образ | Заметки |
|---|---|---|
| **kodikrouter-api** | python:3.12-slim, multi-stage. **CPU-only torch** (`--index-url download.pytorch.org/whl/cpu`) — иначе +3 GB CUDA впустую. Образ без весов | ML-веса НЕ в образе (см. 2.5) |
| **kodikrouter-frontend** | node:22 build → **`output: standalone`** runtime (~150 MB вместо ~1 GB). `NEXT_PUBLIC_API_URL` как `--build-arg` | нужен 1-строчный фикс `next.config` в репо Димы |
| **kodikdetect** | то же (standalone). app в subdir `hive-detector/` | внешние API, секреты рантайм |
| **hackathon-backend** | **уже есть Dockerfile** — переиспользовать | |
| **hackathon-frontend** | новый Dockerfile (standalone) | сейчас на хосте, не контейнеризован |

### 2.5 ML-веса KodikRouter API — initContainer S3-sync (НЕ в образе)

Чистое решение: образ не раздувается, версии моделей развязаны с релизами кода.

```
initContainer (amazon/aws-cli):
  aws --endpoint-url https://s3.ru-3.storage.selcloud.ru s3 sync \
      s3://kodik/anonymizer/ /weights/  (≈2.4 GB, ~30-45 c на network-ssd)
volume: emptyDir (node-local SSD) mount /weights RO в основной контейнер
  → app читает веса из /weights вместо /opt/.../anonymizer
```

S3-креды (`S3_ACCESS_KEY`/`S3_SECRET_KEY`) — из того же Vault-секрета. Минус: ре-download при каждом рестарте/scale-up (приемлемо — масштабируемся редко, NG dedicated). Альтернатива на будущее — RWX PVC (YC NFS) с одной заливкой, если рестарты участятся.

### 2.6 KodikRouter API — ресурсы и анти-bottleneck (КРИТИЧНО)

- **`requests.cpu: 4, limits.cpu: 8`** (DeBERTa жрёт реальный CPU, не burst).
- **`requests.memory: 6Gi, limits.memory: 12Gi`** (RSS покой 3.2 GB, пик с masking выше; `MemoryMax=12G` из systemd). **НЕ 4Gi как в текущем values — это OOM.**
- Все 4 env (`MALLOC_ARENA_MAX`/`MALLOC_TRIM_THRESHOLD_`/`OMP_NUM_THREADS`/`MKL_NUM_THREADS`) + args (`--workers 1 --limit-max-requests 5000 --limit-concurrency 64`).
- `nodeSelector workload=kodikrouter-api` + toleration taint `dedicated=kodikrouter-api:NoSchedule` (dedicated NG).
- `startupProbe` (ML грузится ~30-60 c): `failureThreshold: 30, periodSeconds: 5` → 150 c на cold start; только потом liveness.
- HPA по CPU 70%, min 2 / max 4. PodDisruptionBudget minAvailable=1.
- **Долгосрочно** (не блокер миграции): вынести masking (DeBERTa) в отдельный Deployment — см. `[[reference_kodikrouter_masking_bottleneck_2026_05_21]]`. Сейчас мигрируем as-is.

### 2.7 Данные — миграция БД

| БД | План |
|---|---|
| MySQL 12.7 GB → MDB MySQL `kodikrouter-mysql` | **Не дамп на cutover** (12.7 GB = десятки минут downtime). Вариант 1: YC Data Transfer (MySQL→MDB, near-zero downtime). Вариант 2: внешняя репликация vibekodik-db → MDB за сутки до, на cutover — STOP writes + добить binlog + переключить. Для LIVE-биллинга — минимизировать downtime. **Dry-run импорт за неделю до.** |
| Redis | данных нет (кэш) → просто `REDIS_URL` на MDB Redis, прогрев на лету |
| hackathon postgres (local) | pg_dump → отдельная БД `hackathon` в существующем MDB `kodik-pg` (там уже vault+keycloak). Не-prod → можно и in-cluster StatefulSet, но reuse MDB чище |

### 2.8 Ingress / DNS / TLS

- Per-service `Ingress` (class nginx) + cert-manager TLS (`clusterIssuer letsencrypt-prod`).
- Хосты: `api.kodikrouter.ru`, `kodikrouter.ru`+`www`, `scan.kodik.ru`, `hackathon.kodik.ru` → все на NLB `81.26.176.194`.
- API ingress: `proxy-body-size 32m` (= MAX_REQUEST_BODY_BYTES), `proxy-read-timeout 3600` + `proxy-buffering off` (SSE-стриминг LLM).
- **Cutover:** заранее TTL=60 в Selectel; переключаем A-запись на NLB; учитываем [Selectel UI-vs-authoritative лаг](C:/Users/Ivan/.claude/projects/c--src-kodik/memory/reference_selectel_dns_gotcha.md).

### 2.9 Сеть (NetworkPolicy, default-deny)

Calico уже CNI. По ns:
- `kodikrouter` API → MDB MySQL(3306) + MDB Redis(6379) + 443 (OpenRouter/DO-proxy/OAuth) + Vault(8200). frontend → api (intra-ns).
- `kodikdetect` → 443 (Hive/Sapling) + Vault.
- `hackathon` → MDB PG + Vault.
- ingress-nginx → сервисы с label `expose=true`.

### 2.10 Чего не хватает в текущем generic-чарте `helm/apps/charts/app` (надо доработать)

1. **Нет `initContainers`** → добавить (для ML-весов API).
2. **Нет `volumes`/`volumeMounts`** → добавить (emptyDir весов).
3. **Нет `startupProbe`** → добавить (cold-start ML / Next.js).
4. `externalsecret.yaml` жёстко на `ClusterSecretStore yc-lockbox` → параметризовать (vault-kv).
5. Namespace в values нет → задаётся `-n`, но зафиксировать per-product.
6. Нет `PodDisruptionBudget`, `NetworkPolicy` шаблонов → добавить.

---

## 3. План миграции (порядок по возрастанию риска)

| # | Этап | Блокеры |
|---|---|---|
| C1 | Доработать generic-чарт (init/volumes/startupProbe/vault-store/pdb/netpol) | — |
| C2 | Vault: kv-v2 `kodik/`, k8s-auth, policy, ESO ClusterSecretStore `vault-kv` | нужен Vault CLI или `kubectl exec` |
| C3 | ARC: установить, RunnerScaleSet на 4 репо, YCR-pusher SA | GH App/PAT для ARC |
| **D1** | **kodikdetect** (пилот — stateless, простой): Dockerfile → CI build → Vault `kodikdetect` → helm → cutover `scan.kodik.ru` | — |
| D2 | **kodikrouter-frontend**: standalone-фикс → CI → helm → cutover `kodikrouter.ru` | next.config фикс в репо |
| D3 | **hackathon**: backend (есть Dockerfile) + frontend (новый) + PG в MDB → helm → cutover | репо не склонирован |
| D4 | **kodikrouter-api** (сложный): Dockerfile (CPU-torch) + initContainer-веса → CI → **MySQL data migration** → Vault `kodikrouter-api` → helm → cutover `api.kodikrouter.ru` | DB-миграция 12.7 GB, masking |
| E | Decommission: vibekodik-lb, kodik-ci, monitor, vibekodik-app-01/02/frontend/db, kodik-verify (stop, потом delete через ~неделю) | подтверждение стабильности |

Каждый cutover обратим: вернуть Selectel A-запись на старый IP, старая VM ещё жива ~неделю.

---

## 4. Открытые решения (нужны от Кристиана)

1. **Namespaces per-product** (kodikrouter/kodikdetect/hackathon) vs один `apps`? — рекомендую per-product.
2. **MySQL миграция 12.7 GB**: YC Data Transfer (near-zero downtime) vs репликация vs дамп в окно? — зависит от допустимого downtime биллинга.
3. **hackathon postgres**: в MDB `kodik-pg` (reuse) vs in-cluster StatefulSet? — рекомендую MDB.
4. **next.config standalone-фикс** во фронтах Димы — кто правит (я PR или Дима)?
5. **ARC credentials** — GitHub App (рекомендую) или PAT из памяти?

---

## Связанные памяти
- [[reference_kodik_k8s_migration_2026_05_26]] — инфра-слой, terraform, что live
- [[reference_k8s_vault_keycloak_helm_facts]] — Vault/Keycloak/ESO факты и грабли
- [[reference_kodikrouter_app_env]] — значения секретов для Vault `kodikrouter-api`
- [[reference_kodikrouter_masking_bottleneck_2026_05_21]] — обоснование dedicated NG + долгосрочный split
- [[reference_kodikrouter_dima_memory_tuning_2026_05_21]] — env/limits для API
- [[reference_aiscan_api_keys]] — HIVE/SAPLING для kodikdetect
- [[reference_kodik_hackathon_runbook]] — ADMIN_TOKEN + стек hackathon
- [[reference_selectel_dns_gotcha]] — лаг при cutover
