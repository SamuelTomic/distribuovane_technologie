# Automatické nasadenie lokálneho 3-uzlového clustera (Windows / Docker Desktop).
# Použitie: powershell -ExecutionPolicy Bypass -File .\scripts\deploy-local.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

function New-Secret([int]$Bytes = 24) {
    $buffer = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return ([BitConverter]::ToString($buffer) -replace '-', '').ToLower()
}

if (-not (Test-Path .env)) {
    Write-Host 'Vytváram .env s náhodnými tajomstvami...'
    @(
        'APP_VERSION=1.0.0'
        "REPLICATION_TOKEN=$(New-Secret 32)"
        "DB_PASSWORD=$(New-Secret 16)"
        "DB_ROOT_PASSWORD=$(New-Secret 16)"
    ) | Set-Content -Encoding ascii .env
}

$composeArgs = @('compose', 'up', '-d', '--build', '--wait', '--wait-timeout', '180')
& docker @composeArgs
if ($LASTEXITCODE -ne 0) { throw 'docker compose up zlyhal – pozrite: docker compose logs' }

Write-Host ''
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
Write-Host ''
Write-Host 'Uzol A:  http://localhost:8081'
Write-Host 'Uzol B:  http://localhost:8082'
Write-Host 'Uzol C:  http://localhost:8083'
Write-Host 'Logy:    http://localhost:8090  (Dozzle)'
