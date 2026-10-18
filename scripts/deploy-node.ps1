# Automatické nasadenie jedného uzla na Windows hostiteľovi (Docker Desktop).
# Použitie: .\scripts\deploy-node.ps1 -EnvFile config\hosts\node-a.env [-OpenFirewall]
#   -OpenFirewall (ako administrátor) povolí prichádzajúce spojenia na UI_PORT, PEER_PORT a AGENT_PORT (logy).
param([Parameter(Mandatory)][string]$EnvFile, [switch]$OpenFirewall)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not (Test-Path $EnvFile)) { throw "Súbor $EnvFile neexistuje." }

$config = @{}
Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $config[$k] = $v }

if ($OpenFirewall) {
    foreach ($port in @($config.UI_PORT, $config.PEER_PORT, $config.AGENT_PORT) | Where-Object { $_ }) {
        if (-not (Get-NetFirewallRule -DisplayName "DT uzol $port" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "DT uzol $port" -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
        }
    }
}

$ErrorActionPreference = 'Continue'
docker compose -f docker-compose.node.yml --env-file $EnvFile up -d --build --wait --wait-timeout 600 --remove-orphans
if ($LASTEXITCODE -ne 0) {
    # Napr. zmenená konfigurácia siete – kontajnery a sieť vytvoríme nanovo (volume s dátami ostáva).
    Write-Host 'Prvý pokus zlyhal, vytváram kontajnery a sieť nanovo (dáta ostávajú)...'
    docker compose -f docker-compose.node.yml --env-file $EnvFile down --remove-orphans
    docker compose -f docker-compose.node.yml --env-file $EnvFile up -d --build --wait --wait-timeout 600
}
if ($LASTEXITCODE -ne 0) { throw 'Nasadenie zlyhalo – pozrite docker compose -f docker-compose.node.yml logs' }
docker compose -f docker-compose.node.yml --env-file $EnvFile ps

Write-Host "`nUzol $($config.NODE_ID) beží: http://localhost:$($config.UI_PORT)"
Write-Host 'Dostupnosť peerov:'
foreach ($entry in $config.PEER_NODES -split ',') {
    $node, $url = $entry -split '=', 2
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$url/api/status" | Out-Null; Write-Host "  $node  $url  online" }
    catch { Write-Host "  $node  $url  NEDOSTUPNÝ (zatiaľ)" }
}
