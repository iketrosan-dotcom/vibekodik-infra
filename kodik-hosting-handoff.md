# Kodik Hosting Provider — VM готова, handoff backend-команде

Всё что Кристиан развернул на стороне инфры 2026-05-20.

## Что уже работает

| | Value |
|---|---|
| **VM** | `kodik-hosting` (Yandex Cloud, ID `fhm1uibdi5n5hu48tv1c`) |
| **Public IP** | `111.88.249.46` (ephemeral NAT — **НЕ стопать VM**, IP сменится; reboot ОК, stop+start = новый IP) |
| **Internal IP** | `10.128.0.14` (VPC `default`, ru-central1-a) |
| **Internal FQDN** | `kodik-hosting.ru-central1.internal` |
| **SSH** | `ssh -p 5722 -i ~/.ssh/id_ed25519 ubuntu@111.88.249.46` (нужен публичный ключ ниже) |
| **Resources** | 4 vCPU / 8 GB RAM / 80 GB SSD + swap=нет (свободно ~75 GB) |
| **OS** | Ubuntu 22.04 LTS |
| **Firewall** | ufw deny incoming; allow 5722/80/443. `:8082` и `:2019` — loopback only ✅ |
| **Docker** | v29.5.1, running |
| **Caddy** | v2.11.3, running, `/etc/caddy/caddy.json` (admin :2019, server srv0 :443 пустой) |
| **Python** | 3.11.15 (для venv hosting-provider) |
| **System user** | `kodik` (uid 999), nologin shell, в группах `docker` |
| **Dirs** | `/opt/kodik/hosting-provider/` (пустой, ждёт ваш код), `/var/lib/kodik-hosting/`, `/etc/kodik/` |
| **Env file** | `/etc/kodik/hosting-provider.env` — все поля кроме токена готовы |
| **fail2ban** | sshd jail на 5722, maxretry 5 / bantime 1h |
| **Cron** | `docker system prune -af --filter "until=168h"` каждое вс 04:00 |
| **DNS** | wildcard `*.apps.kodik.ru → 111.88.249.46` (Selectel, TTL 300) ✅ |

## Что нужно от backend-команды

1. **HOSTING_PROVIDER_TOKEN** — реальное значение. Сейчас в `/etc/kodik/hosting-provider.env` стоит `REPLACE_ME_REAL_TOKEN_FROM_BACKEND_TEAM`.
2. **URL git-репо** где лежит код hosting-provider (предположительно subdir `hosting-provider/` в Kodik-API репо).
3. **SSH-ключ** того, кто будет ставить сервис на VM (мне передать pubkey, я залью в `~ubuntu/.ssh/authorized_keys` или создам отдельного юзера).
4. **С какого сервера/IP** Kodik-API будет дёргать `:8082`. Сейчас `:8082` снаружи закрыт ufw. Варианты:
   - вы уже в той же VPC (`b1gbv2g55ag1fhq0ckii`, subnet `default` ru-central1-a) — тогда зовите по `kodik-hosting.ru-central1.internal:8082` (но надо добавить ingress 8082 в security group от вашей SG)
   - вы снаружи — дайте IP, я открою ingress 8082 только с него

## Шаги завершения деплоя (когда придут токен + URL репо)

```bash
ssh -p 5722 -i ~/.ssh/id_ed25519 ubuntu@111.88.249.46

# 1. подменить токен
sudo sed -i 's|REPLACE_ME_REAL_TOKEN_FROM_BACKEND_TEAM|<real-token>|' /etc/kodik/hosting-provider.env

# 2. склонировать репо и разложить
sudo -u kodik git clone <repo-url> /tmp/kodik-api
sudo cp -r /tmp/kodik-api/hosting-provider/. /opt/kodik/hosting-provider/
sudo chown -R kodik:kodik /opt/kodik/hosting-provider

# 3. venv + deps
cd /opt/kodik/hosting-provider
sudo -u kodik python3.11 -m venv .venv
sudo -u kodik .venv/bin/pip install --upgrade pip
sudo -u kodik .venv/bin/pip install fastapi uvicorn pydantic pydantic-settings httpx
# (или pip install -r requirements.txt если есть)

# 4. systemd
sudo cp deploy/kodik-hosting-provider.service /etc/systemd/system/
sudo cp deploy/kodik-hosting-worker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kodik-hosting-provider.service kodik-hosting-worker.service

# 5. healthcheck
curl http://localhost:8082/health
# {"ok":true,"dbReachable":true,"dockerReachable":true,"queueDepth":0}
```

## Диагностика

```bash
# Очередь сборок + общее
curl http://localhost:8082/health

# Логи provider+worker
sudo journalctl -u kodik-hosting-provider -u kodik-hosting-worker -f

# Логи Caddy
sudo journalctl -u caddy -f

# Список Caddy-маршрутов (кто добавил какой поддомен)
curl -s http://localhost:2019/config/apps/http/servers/srv0/routes | jq

# Контейнеры
sudo -u kodik docker ps
```

## Контакты

- **DevOps:** Кристиан (`@kristian` в slack)
- Yandex Cloud console: https://console.yandex.cloud/folders/b1gdrsc5c0l86vvjs95l/compute/instance/fhm1uibdi5n5hu48tv1c
