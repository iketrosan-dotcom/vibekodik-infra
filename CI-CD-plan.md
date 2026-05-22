# CI/CD план для KodikRouter (backend + frontend) — self-hosted runner

**Дата:** 2026-05-14
**Автор:** Claude (для Кристиана)
**Статус:** ⏸️ ЧЕРНОВИК НА СОГЛАСОВАНИЕ — ничего ещё не сделано

---

## 1. Аудит текущего состояния

### 1.1 Репозитории (выдержка из GitHub API на 2026-05-14)

| Репо | Stack | Последний push | Тесты | Есть `.github/workflows`? |
|---|---|---|---|---|
| `mike2505/KodikRouterAPI` | Python 3.12, FastAPI, alembic, pytest, MySQL, Redis | 2026-05-14 12:53 MSK | ✅ ~24 файла pytest | ❌ нет |
| `mike2505/KodikRouterFront` | Next.js 16, React 19, TS, Tailwind 4 | 2026-05-14 14:12 MSK | ❌ нет тестов | ❌ нет |

### 1.2 Что есть в инфре

| Что | Где | Использует |
|---|---|---|
| Backend service | `vibekodik-app-01` + `vibekodik-app-02` (private) | systemd `kodikrouter-api`, uvicorn × 4 workers, `:8000` |
| Frontend service | `vibekodik-frontend` (private) | systemd `kodikrouter-frontend`, Next.js, `:3000` |
| MySQL + Redis | `vibekodik-db` (private) | Backend читает по `vibekodik-db.ru-central1.internal` |
| Load balancer | `vibekodik-lb` (public `111.88.250.108`) | nginx TLS, host-based: `api.kodikrouter.ru` → app pool, `www`/apex → frontend pool |
| Bastion (SSH gateway) | `relayer-01` (public `111.88.241.3:5722`) | ProxyJump во все приватные VM |

Code paths:
- Backend: `/opt/vibekodik/api` (git checkout, python venv в `./env/`)
- Frontend: `/opt/vibekodik-frontend/app` (git checkout, node_modules + .next в одной директории)

### 1.3 Текущий ручной deploy flow

```bash
# Backend (по очереди для app-01, app-02 — rolling restart)
ssh vibekodik-app-01 '
  cd /opt/vibekodik/api
  git pull --ff-only origin main
  ./env/bin/alembic upgrade head   # если есть новые миграции
  sudo systemctl restart kodikrouter-api
'
# Health check ~15 сек прогрева ML, потом то же на app-02

# Frontend
ssh vibekodik-frontend '
  cd /opt/vibekodik-frontend/app
  git pull --ff-only origin main
  npm ci
  NODE_ENV=production npm run build
  sudo systemctl restart kodikrouter-frontend
'
```

Сейчас цикл занимает 1–3 минуты на backend + ~2 минуты на frontend, делается ВРУЧНУЮ при пинге от Димы.

### 1.4 Что в этом плохо (мотивация CI/CD)

| Проблема | Последствие |
|---|---|
| Деплой только когда кто-то у компа | Бутылочное горлышко на тебе/мне |
| Нет тестов в pipeline | Сломанный код доезжает до прода без preview |
| Нет rolling-health-check между app-01 и app-02 | Возможен момент, когда оба перезагружаются одновременно (если ручник ошибся) |
| Нет history какой commit когда задеплоен | После инцидента сложно сказать «откуда баг» |
| Нет автоматического rollback | Нужно вручную `git reset --hard <prev>` + restart |
| Секреты `.env` не отслеживаются | При перенакате VM теряются — записаны только в memory вручную |

---

## 2. Предлагаемая архитектура

### 2.1 Где живёт runner

**Рекомендую: новая VM `kodik-ci`** (2 vCPU 100% / 4 GB RAM / 30 GB SSD).

Почему не на существующих:
- `relayer-01` — bastion, и так нагружен SSH-сессиями, маленький (1 GB RAM)
- `app-01/02/frontend` — production, build на них съест ресурсы у прод-нагрузки
- `kodik-verify` — независимый продукт, мешать ему не надо

Альтернатива: **GitHub-hosted runners** (бесплатно для public repo, $0.008/мин для private). Минусы: нет доступа в нашу private subnet (10.128.0.0/24) → деплой только через SSH bastion с публичным IP → лишний хоп. Плюсы: ничего не админить.

**Решение зависит от тебя:**
- A) Своя `kodik-ci` VM (рекомендую)
- B) GitHub-hosted (проще, но менее гибко)
- C) Использовать relayer-01 как runner (бесплатно, но тесно)

### 2.2 Архитектура runner→VM

```
GitHub push event (main branch)
        │
        ▼
GitHub Actions API → ставит job в очередь
        │
        ▼
self-hosted runner на kodik-ci (polling каждые 1-2 сек)
        │
        ├── workflow для KodikRouterAPI:
        │     1. checkout (git pull в /opt/builds/api)
        │     2. (опц.) pytest на runner-е
        │     3. ssh vibekodik-app-01 → git pull → alembic upgrade → restart → wait health
        │     4. ssh vibekodik-app-02 → то же (rolling)
        │     5. smoke: curl https://api.kodikrouter.ru/health → 200
        │     6. notify Telegram (опц.)
        │
        └── workflow для KodikRouterFront:
              1. checkout
              2. (опц.) eslint на runner-е
              3. ssh vibekodik-frontend → git pull → npm ci → build → restart
              4. smoke: curl https://kodikrouter.ru/ → 200
```

### 2.3 SSH access для runner-а

Runner ходит в наши VM как user `ci-deploy` (новый, отдельный от `ubuntu`).
- Создаём `ci-deploy` user на app-01, app-02, frontend
- Даём ему sudo NOPASSWD только на: `systemctl restart kodikrouter-*`, `systemctl restart kodikrouter-frontend`
- НЕТ полного `sudo NOPASSWD:ALL` — изоляция (если runner скомпрометирован, не дадим root)
- SSH key pair: генерим на kodik-ci, public кладём в `~ci-deploy/.ssh/authorized_keys` на target VM

### 2.4 Secrets management

В GitHub Actions secrets хранятся **только**:
- `RUNNER_TOKEN` — для регистрации runner-а (но раз runner self-hosted, можно совсем без GH secrets)
- Опц. `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` — для уведомлений

**.env файлы остаются на target VM** — runner их не видит, не копирует, не пушит в GH. Это даёт чистый bond «код→main», «секреты→prod-only».

### 2.5 Rollback стратегия

После каждого успешного деплоя workflow пишет файл `/opt/vibekodik/api/.last-good-sha`. Если деплой провалился на health-check:

```bash
git reset --hard $(cat /opt/vibekodik/api/.last-good-sha)
sudo systemctl restart kodikrouter-api
```

Дополнительно — manual rollback workflow:
```yaml
on: workflow_dispatch
inputs:
  sha: required commit to rollback to
```
Кристиан запускает из GH UI → runner SSH-ит в VMs → reset → restart.

### 2.6 Branch strategy

**Старт:** push в `main` → auto deploy в prod (как сейчас, без staging — Дима пушит уже проверенный код).

**Через 2-4 недели**, если что-то полетит несколько раз — добавим:
- `dev` branch → staging environment (новая VM, или k8s namespace)
- PR review + tests перед merge в `main`
- `main` → prod

Пока стартуем с прямым `push to main → prod` чтобы не усложнять.

### 2.7 Уведомления

Опционально (рекомендую): Telegram bot пишет в группу/тебе:
- ✅ Deploy KodikRouterAPI `commit-sha` succeeded in 1m23s
- ❌ Deploy KodikRouterFront `commit-sha` FAILED at step `npm run build`

Нужно создать bot @BotFather, получить token, узнать chat_id. Это `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` в GH Actions secrets.

---

## 3. Поэтапный план реализации

### Этап 0 — Подготовка (твоя сторона, ~15 мин)

- [ ] **Согласовать этот план** (всё, что в разделе 4 «Open questions»)
- [ ] **Telegram bot** (если хочешь уведомления) — создать через @BotFather, получить токен + chat_id

### Этап 1 — kodik-ci VM (~30 мин)

- [ ] Создать VM `kodik-ci` в YC: 2 vCPU 100% / 4 GB / 30 GB SSD, Ubuntu 24.04, default VPC, SG: только egress (без публичного IP вообще — пусть ходит через NAT gateway)
  - SSH доступ через bastion (как остальные prod VMs)
- [ ] Cloud-init установит: git, docker, python3, nodejs 22, build-essential, fail2ban
- [ ] Установить GitHub Actions runner agent (`actions/runner`) на эту VM
- [ ] Зарегистрировать runner для **organization-level** (не repo-level) — один runner обслуживает оба репо

### Этап 2 — SSH доступ runner→app/frontend (~15 мин)

- [ ] На kodik-ci сгенерить ssh keypair `ci_deploy_ed25519`
- [ ] На app-01, app-02, vibekodik-frontend:
  - Создать user `ci-deploy`
  - `~/.ssh/authorized_keys` ← public key с kodik-ci
  - `/etc/sudoers.d/ci-deploy`:
    ```
    ci-deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart kodikrouter-api, /usr/bin/systemctl restart kodikrouter-frontend
    ci-deploy ALL=(ubuntu) NOPASSWD: ALL    # для запуска alembic / git pull под ubuntu user
    ```
  - Дать `ci-deploy` read+write на `/opt/vibekodik/api` (или сделать его в группе `ubuntu`)

### Этап 3 — Backend workflow (~1 час)

Создать `.github/workflows/deploy.yml` в `KodikRouterAPI`:

```yaml
name: Deploy backend

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      sha:
        description: 'commit SHA to deploy (для rollback)'
        required: false

concurrency:
  group: deploy-backend       # запретить параллельные деплои
  cancel-in-progress: false

jobs:
  test:
    runs-on: [self-hosted, kodik]
    steps:
      - uses: actions/checkout@v4
      - name: Setup Python
        run: python3.12 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
      - name: Pytest
        run: ./.venv/bin/pytest -x --tb=short
        # ⚠️ тесты могут требовать DB/Redis — настроим mock или skip integration-suite
        continue-on-error: true   # на старте не блокируем

  deploy:
    needs: test
    runs-on: [self-hosted, kodik]
    steps:
      - name: Deploy app-01
        run: |
          ssh ci-deploy@vibekodik-app-01.internal '
            set -e
            cd /opt/vibekodik/api
            echo $(git rev-parse HEAD) > .last-good-sha   # save current as rollback point
            sudo -u ubuntu git pull --ff-only origin main
            sudo -u ubuntu ./env/bin/alembic upgrade head
            sudo systemctl restart kodikrouter-api
          '
      - name: Health check app-01
        run: |
          for i in {1..30}; do
            code=$(ssh ci-deploy@vibekodik-app-01.internal \
              "curl -sS -o /dev/null -w %{http_code} http://127.0.0.1:8000/health")
            [ "$code" = "200" ] && break
            sleep 2
          done
          [ "$code" = "200" ] || { echo "app-01 health failed"; exit 1; }

      - name: Deploy app-02 (only if app-01 healthy)
        run: |
          ssh ci-deploy@vibekodik-app-02.internal '
            cd /opt/vibekodik/api
            echo $(git rev-parse HEAD) > .last-good-sha
            sudo -u ubuntu git pull --ff-only origin main
            sudo systemctl restart kodikrouter-api
          '
      - name: Health check app-02
        # same loop

      - name: Public smoke
        run: |
          curl -sSf https://api.kodikrouter.ru/health > /dev/null
          echo "✅ backend deploy ok"

      - name: Notify Telegram (success)
        if: success()
        run: |
          curl -sS "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d "chat_id=$CHAT_ID" -d "text=✅ KodikRouterAPI deployed ${{ github.sha }} on $(date)"
        env:
          BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}

      - name: Notify Telegram (failure)
        if: failure()
        run: |
          curl -sS "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d "chat_id=$CHAT_ID" -d "text=❌ KodikRouterAPI DEPLOY FAILED ${{ github.sha }}"
        env:
          BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
```

### Этап 4 — Frontend workflow (~30 мин)

`.github/workflows/deploy.yml` в `KodikRouterFront`:

```yaml
name: Deploy frontend

on:
  push:
    branches: [main]

concurrency:
  group: deploy-frontend
  cancel-in-progress: true   # для frontend ОК отменять, последний коммит важнее

jobs:
  deploy:
    runs-on: [self-hosted, kodik]
    steps:
      - name: Deploy
        run: |
          ssh ci-deploy@vibekodik-frontend.internal '
            set -e
            cd /opt/vibekodik-frontend/app
            echo $(git rev-parse HEAD) > .last-good-sha
            sudo -u ubuntu git pull --ff-only origin main
            sudo -u ubuntu npm ci
            sudo -u ubuntu env NODE_ENV=production npm run build
            sudo systemctl restart kodikrouter-frontend
          '
      - name: Public smoke
        run: curl -sSf https://kodikrouter.ru/ > /dev/null
      - name: Notify Telegram
        # same as backend
```

### Этап 5 — Roll-out (~30 мин)

- [ ] Создать PR в каждом репо: `.github/workflows/deploy.yml`
- [ ] Merge в `main` — это сам запустит первый авто-деплой
- [ ] Наблюдать первые 2-3 деплоя через GH Actions UI
- [ ] Если что-то — `workflow_dispatch` с SHA → rollback

### Этап 6 — Улучшения (через 1-2 недели)

- [ ] Включить tests как required (сейчас `continue-on-error: true`)
- [ ] Метрики: сколько раз в день деплой, сколько failures, MTTR (mean time to recovery)
- [ ] Добавить slack-уведомления для тебя/Димы для PR review (если введём dev-branch flow)
- [ ] Pre-deploy diff: показывать в Telegram-сообщении список изменённых файлов
- [ ] Staging environment (если будут регрессии)

---

## 4. Open questions для тебя (Кристиан)

⚠️ **Перед тем как я начну делать — ответь на эти:**

1. **Где runner?**
   - A) Новая VM `kodik-ci` (рекомендую, +30-50 ₽/день за ресурсы)
   - B) GitHub-hosted ($0.008/мин для private repos, ~$1-2/мес при текущей частоте деплоев)
   - C) На relayer-01 (бесплатно, но тесно — 1 GB RAM)

2. **KodikDetect (scan.kodik.ru) тоже автодеплоить?** — Дима пушит туда часто. Если да — добавлю третий workflow.

3. **Tests в CI делаем или skip на старте?**
   - A) Skip — деплой будет быстрее (~2 мин вместо ~4 мин)
   - B) Запускаем pytest, на падении блокируем деплой
   - C) Запускаем, но `continue-on-error: true` (получаем сигнал, не блокируем)

4. **Telegram-уведомления?**
   - Если да — создай бота через @BotFather, дай мне token + chat_id (пиши в личку боту /start, я через `getUpdates` узнаю chat_id)

5. **Прямой push→prod или PR-flow?**
   - A) `git push main → auto deploy` (как сейчас, проще)
   - B) `git push → PR → review → merge → deploy` (безопаснее, но Дима один разработчик — кому review делать?)

6. **GitHub Actions concurrency** — окей если **второй пуш отменяет первый** на frontend (поскольку frontend «всегда последняя версия лучше»)? Для backend строго `cancel-in-progress: false` (нельзя прерывать на середине rolling restart).

7. **Что делать когда meeting/демо** — нужен ли «deploy lock» (workflow_dispatch=manual только) на критичные часы? Или продолжаем «всё пушится автоматом всегда»?

---

## 5. Что я НЕ буду делать без твоего одобрения

- Создавать VM (стоит денег)
- Менять `.env` или secrets
- Деплоить change-y от других PR'ов
- Отключать текущий manual deploy flow до того как auto-deploy подтверждённо работает
- Регистрировать GitHub runner в твоём аккаунте

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Runner упадёт → деплой не работает | Manual deploy всегда доступен (как сейчас). Health monitoring runner-а в Telegram |
| ci-deploy user скомпрометирован | sudo только на `systemctl restart`, no `ALL` |
| Alembic migration ломает prod | Тесты на dev-копии DB перед prod-миграцией; всегда есть `alembic downgrade -1` |
| Deploy в момент демо | Можно временно `workflow_dispatch` only (через GH UI отключить trigger по push) |
| Runner secret token утечёт | Это token для регистрации runner-а у GH, не для prod access. Ротируется в 5 кликов |
| .env разъезжается с .env.example | Этап 6: добавить step «проверка что в .env.example есть все ключи из app/core/config.py» |

---

## 7. Стоимость

| Item | Cost |
|---|---|
| Новая VM `kodik-ci` (если выберем вариант A) | ~30-50 ₽/день = ~1000-1500 ₽/мес в YC |
| GitHub-hosted runners (если вариант B) | $0.008/мин × ~50 деплоев × 3 мин = $1.2/мес для private repo |
| GH Actions storage (logs) | бесплатно до 2GB для public, 500MB для private — нам хватит |
| Telegram bot | бесплатно |
| **Итого** | **~$15-20/мес** на варианте A, **~$1-2/мес** на варианте B |

---

## Итого

Спроектировал, ничего не трогал на проде. Жду ответы на 7 open questions из раздела 4 — после согласования начинаем с этапа 1.

Кратко самое важное: **есть ли деньги на новую маленькую VM kodik-ci (~1500 ₽/мес)** или идём через GitHub-hosted runners (~$1-2/мес, но ограниченнее).
