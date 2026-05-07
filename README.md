# vibekodik-infra

Infrastructure-as-Code для AI-платформы vibekodik.

Содержит две независимые инсталляции:

1. **Yandex Cloud (RU)** — основной prod-стек (LB + 2 app + frontend + DB + bastion-релейер).
2. **DigitalOcean (Frankfurt)** — outbound LLM-прокси, чтобы запросы из RU backend к OpenAI/Anthropic/etc уходили с зарубежного IP (provider'ы блокируют русские IP).

## Архитектура — RU prod (Yandex Cloud)

```
                   internet
                      │
              ┌───────┴────────┐
              │                │
         vibekodik-lb     relayer-01
        (public, TLS)    (public, bastion)
              │                │
   ┌──────────┼──────────┐     │
   │          │          │     │ SSH proxy
   ▼          ▼          ▼     │
 app-01     app-02   frontend  │
(FastAPI) (FastAPI)  (Next.js) │
   │          │          │     │
   └────┬─────┴──────────┘     │
        ▼                      │
     vibekodik-db ◄─────────── ┘ (admin SSH)
   (MySQL 8 + Redis 7,
    private only)
```

Все prod-VM в private subnet `10.128.1.0/24`. Публичный доступ только у LB. SSH ко всем prod-машинам идёт через bastion (`relayer-01`). Egress в интернет — через NAT gateway.

## Файлы

| Файл | Назначение |
|---|---|
| [`cloud-init-relayer.yaml`](cloud-init-relayer.yaml) | Релейер: nginx reverse-proxy `relayer.vibekodik.ru` → `api.vibekodik.ru` (обход РКН-блокировки маршрутов). Сейчас также используется как bastion для prod. |
| [`cloud-init-lb.yaml`](cloud-init-lb.yaml) | Load Balancer: nginx с TLS termination + HTTP routing (`/api/` → backend pool, `/` → frontend), SSE-aware (long timeouts, no buffering). |
| [`cloud-init-app.yaml`](cloud-init-app.yaml) | Backend app servers: окружение Python 3.12 + venv + build deps под FastAPI/uvicorn + PyTorch CPU + GLiNER. Код деплоится отдельно. |
| [`cloud-init-frontend.yaml`](cloud-init-frontend.yaml) | Frontend: Node.js 22 LTS + npm. Код деплоится отдельно. |
| [`cloud-init-db.yaml`](cloud-init-db.yaml) | MySQL 8 + Redis 7 (co-located). innodb_buffer_pool_size=10G, log_bin на отдельный volume. AppArmor override для custom binlog dir. |
| [`create-prod-vms.ps1`](create-prod-vms.ps1) | Bootstrap-скрипт: резервирует static IP и создаёт все 5 prod-VM одной серией (с pre-flight quota check). |
| [`quota-request.md`](quota-request.md) | Шпаргалка какие квоты YC и до каких значений запрашивать перед запуском prod. |
| [`bootstrap-do-proxy.sh`](bootstrap-do-proxy.sh) | Bootstrap для DO-прокси VM (Frankfurt) — outbound proxy для LLM-провайдеров. См. ниже. |

## Архитектура — outbound LLM-proxy (DigitalOcean Frankfurt)

Отдельные VPS у DigitalOcean во Frankfurt. Назначение: backend в РФ → LLM-провайдеры (OpenAI/Anthropic/etc.) идут не напрямую (provider блокирует РФ-IP), а через эти прокси. Provider видит немецкий IP — пропускает.

```
                 [user]
                   ↓
              [RU backend]
                   ↓ (LLM call с заголовком X-Target-URL)
   ┌───────────────┴───────────────┐
   ↓                               ↓
proxy.kodik.ru                  proxy.kodikrouter.ru
(157.230.120.167)               (64.226.78.10)
   ↓                               ↓
   └─────────► [provider] ◄────────┘
       (api.openai.com, api.anthropic.com, ...)
```

Две VM нужны под два бизнес-продукта (Kodik и KodikRouter), чтобы разделить биллинг и изолировать failure domain.

**Состояние (2026-05-07):**

| | `proxy.kodik.ru` (157.230.120.167) | `proxy.kodikrouter.ru` (64.226.78.10) |
|---|---|---|
| Bootstrap (nginx/fail2ban/ufw/swap) | ✅ | ✅ |
| forward-proxy конфиг (X-Target-URL + Bearer auth + whitelist 8 LLM provider'ов) | ✅ | ✅ |
| DNS A-record | ✅ | ✅ (Selectel zone, добавлено 2026-05-07) |
| Let's Encrypt cert | ✅ до 2026-08-05 | ✅ до 2026-08-05 |
| HTTPS + redirect 80→443 | ✅ | ✅ |
| Bearer-токен ротирован после TLS | ✅ | ✅ |

Шаблоны:
- [`bootstrap-do-proxy.sh`](bootstrap-do-proxy.sh) — базовый bootstrap (apt, swap, fail2ban, ufw, default 444).
- [`nginx-llm-proxy.conf.template`](nginx-llm-proxy.conf.template) — HTTP-only forward-proxy (фаза без TLS).
- [`nginx-llm-proxy-tls.conf.template`](nginx-llm-proxy-tls.conf.template) — финальная TLS-версия (HTTP→HTTPS redirect, 443 ssl, default 444 для чужих SNI/Host).

Бережно к секретам:
- Токены **не в репо** — лежат локально в `proxy-tokens.txt` (gitignored). Backend получает через `.env`.
- Приватный SSH-ключ от DO — `~/.ssh/id_rsa_kodik` (был получен через Telegram, после деплоя на kodikrouter рекомендуется его сменить).

## Общие принципы

- **Cloud-init `write_files` + base64** — YC metadata-API жуёт `$VAR` из user-data, любые nginx-конфиги с `$remote_addr` и подобным кодируем в base64.
- **SSH порт 5722** на всех VM, password-auth выключен.
- **fail2ban** на всех (sshd jail: maxretry=5, findtime=10m, bantime=1h).
- **unattended-upgrades** для патчей безопасности.
- **Swap** 1 GB на LB / 4 GB на app/frontend/DB (страховка от OOM).
- **Hardening nginx**: `server_tokens off`, rate-limit, conn-limit на всех LB-конфигах.

## Воспроизведение с нуля

1. Установить `yc` CLI, авторизоваться: `yc init`.
2. Запросить квоты по [`quota-request.md`](quota-request.md), дождаться одобрения.
3. Создать VPC subnet + NAT gateway + 4 SG (см. inline комментарии в скрипте).
4. Запустить `pwsh create-prod-vms.ps1`.
5. После cloud-init завершится — деплоить код приложения на app/frontend и поднимать БД-схему на db.
