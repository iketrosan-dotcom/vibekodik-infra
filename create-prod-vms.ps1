# Создание prod-инфры vibekodik в Yandex Cloud.
# Запуск: pwsh c:\src\kodik\create-prod-vms.ps1
#
# Что создаёт:
#   - 1 static external IP (для LB)
#   - vibekodik-lb        (2 vCPU / 4 GB / 40 GB SSD,  public IP, lb-sg)
#   - vibekodik-app-01    (8 vCPU / 16 GB / 186 GB NRD, no public IP, app-sg)
#   - vibekodik-app-02    (8 vCPU / 16 GB / 186 GB NRD, no public IP, app-sg)
#   - vibekodik-frontend  (8 vCPU / 16 GB / 186 GB NRD, no public IP, frontend-sg)
#   - vibekodik-db        (4 vCPU / 16 GB / 250 GB IO-M3 boot + 100 GB SSD secondary, no public IP, db-sg)
#
# Все в subnet vibekodik-prod-a (10.128.1.0/24, ru-central1-a). Egress private VM — через NAT gateway.
# Boot OS: Ubuntu 24.04 LTS (image fd8lqpb6d8fu6jsoefot).
# Платформа: standard-v3 (Intel Ice Lake, AVX-512).
# Cloud-init: c:\src\kodik\cloud-init-{lb,app,frontend,db}.yaml.
#
# ВАЖНО:
# - DB не запустится без увеличенной квоты compute.ssdIOM3Disks.size (нужно ≥350 GB, текущая 186 GB).
# - App / Frontend требуют квоту compute.ssdNonReplicatedDisks.size ≥ 558 GB (текущая 558 GB — точно).
# - Скрипт проверит квоты перед запуском и остановится если что-то не хватает.

$ErrorActionPreference = "Stop"
$yc = "$env:USERPROFILE\yandex-cloud\bin\yc.exe"

# === ID ресурсов (уже созданы) ===
$image      = "fd8lqpb6d8fu6jsoefot"          # ubuntu-2404-lts
$subnet     = "e9brf4qmd9k1c9i6ehr7"          # vibekodik-prod-a, 10.128.1.0/24
$sgLb       = "enpvqijv7or1rqk6kmjh"          # vibekodik-lb-sg
$sgApp      = "enpov90vjfifj2djeo2p"          # vibekodik-app-sg
$sgFrontend = "enphcbh77d4r6dd8c31j"          # vibekodik-frontend-sg
$sgDb       = "enpmqtctmjtechua1c72"          # vibekodik-db-sg
$ciDir      = "c:\src\kodik"

# === pre-flight quota check ===
Write-Host "=== Quota pre-flight ===" -ForegroundColor Cyan
$quotas = & $yc quota-manager quota-limit list --service compute --resource-id b1gbv2g55ag1fhq0ckii --resource-type "resource-manager.cloud" --format json | ConvertFrom-Json
function Get-Quota($id) { ($quotas | Where-Object { $_.quotaId -eq $id }).limit }
$nrd  = Get-Quota "compute.ssdNonReplicatedDisks.size"
$io   = Get-Quota "compute.ssdIOM3Disks.size"
$ssd  = Get-Quota "compute.ssdDisks.size"
$cores= Get-Quota "compute.instanceCores.count"

$nrdNeed  = 186GB * 3                           # 3 × NRD-диск (app×2 + frontend)
$ioNeed   = 250GB                               # DB boot
$ssdNeed  = 40GB + 100GB                        # LB + DB binlogs
$coreNeed = 30                                  # 2+8+8+8+4

$ok = $true
if ($nrd  -lt $nrdNeed)  { Write-Host "❌ NRD: have $([Math]::Round($nrd/1GB)) GB, need $([Math]::Round($nrdNeed/1GB)) GB"  -ForegroundColor Red; $ok = $false }
if ($io   -lt $ioNeed)   { Write-Host "❌ IO-M3: have $([Math]::Round($io/1GB)) GB, need $([Math]::Round($ioNeed/1GB)) GB" -ForegroundColor Red; $ok = $false }
if ($ssd  -lt $ssdNeed)  { Write-Host "❌ SSD: have $([Math]::Round($ssd/1GB)) GB, need $([Math]::Round($ssdNeed/1GB)) GB" -ForegroundColor Red; $ok = $false }
if ($cores -lt $coreNeed){ Write-Host "❌ vCPU: have $cores, need $coreNeed"                                                -ForegroundColor Red; $ok = $false }

if (-not $ok) {
    Write-Host "`nKвоты не хватает. Жди апрува YC support по quota-request.md, потом запусти скрипт снова." -ForegroundColor Yellow
    exit 1
}
Write-Host "✓ All quotas OK" -ForegroundColor Green

# === 1. Reserve static IP for LB ===
Write-Host "`n=== Reserving static IP for LB ===" -ForegroundColor Cyan
& $yc vpc address create --name vibekodik-lb-ip --description "Static public IP for vibekodik-lb" --external-ipv4 zone=ru-central1-a
$lbIp = (& $yc vpc address get vibekodik-lb-ip --format json | ConvertFrom-Json).external_ipv4_address.address
Write-Host "LB static IP: $lbIp" -ForegroundColor Green

# === 2. Load Balancer ===
Write-Host "`n=== Creating vibekodik-lb ===" -ForegroundColor Cyan
& $yc compute instance create `
  --name vibekodik-lb --hostname vibekodik-lb `
  --zone ru-central1-a --platform standard-v3 `
  --cores 2 --core-fraction 100 --memory 4G `
  --create-boot-disk "image-id=$image,size=40G,type=network-ssd" `
  --network-interface "subnet-id=$subnet,nat-ip-version=ipv4,nat-address=$lbIp,security-group-ids=$sgLb" `
  --metadata-from-file user-data="$ciDir\cloud-init-lb.yaml"

# === 3. DB (нужны IO-M3 квоты) ===
Write-Host "`n=== Creating vibekodik-db ===" -ForegroundColor Cyan
& $yc compute instance create `
  --name vibekodik-db --hostname vibekodik-db `
  --zone ru-central1-a --platform standard-v3 `
  --cores 4 --core-fraction 100 --memory 16G `
  --create-boot-disk "image-id=$image,size=250G,type=network-ssd-io-m3" `
  --create-disk "size=100G,type=network-ssd,name=vibekodik-db-binlogs" `
  --network-interface "subnet-id=$subnet,security-group-ids=$sgDb" `
  --metadata-from-file user-data="$ciDir\cloud-init-db.yaml"

# === 4. App backend × 2 ===
foreach ($n in @("01","02")) {
    Write-Host "`n=== Creating vibekodik-app-$n ===" -ForegroundColor Cyan
    & $yc compute instance create `
      --name "vibekodik-app-$n" --hostname "vibekodik-app-$n" `
      --zone ru-central1-a --platform standard-v3 `
      --cores 8 --core-fraction 100 --memory 16G `
      --create-boot-disk "image-id=$image,size=186G,type=network-ssd-nonreplicated" `
      --network-interface "subnet-id=$subnet,security-group-ids=$sgApp" `
      --metadata-from-file user-data="$ciDir\cloud-init-app.yaml"
}

# === 5. Frontend ===
Write-Host "`n=== Creating vibekodik-frontend ===" -ForegroundColor Cyan
& $yc compute instance create `
  --name vibekodik-frontend --hostname vibekodik-frontend `
  --zone ru-central1-a --platform standard-v3 `
  --cores 8 --core-fraction 100 --memory 16G `
  --create-boot-disk "image-id=$image,size=186G,type=network-ssd-nonreplicated" `
  --network-interface "subnet-id=$subnet,security-group-ids=$sgFrontend" `
  --metadata-from-file user-data="$ciDir\cloud-init-frontend.yaml"

# === Summary ===
Write-Host "`n=== Done. State: ===" -ForegroundColor Cyan
& $yc compute instance list
Write-Host "`nLB public IP: $lbIp" -ForegroundColor Green
Write-Host "Cloud-init logs (если что не работает): ssh ubuntu@<vm> -p 5722 'sudo cloud-init status --long; sudo tail /var/log/cloud-init-output.log'" -ForegroundColor Yellow
