# Vygeneruje konfiguračné súbory pre 3 hostitele (PC, VM, ďalší PC) so spoločným náhodným tokenom.
# Použitie: .\scripts\new-host-configs.ps1 -IpA 192.168.1.10 -IpB 192.168.1.20 -IpC 192.168.1.30
# Výsledok: config/hosts/node-a.env, node-b.env, node-c.env → skopírujte projekt na každý hostiteľ.
param(
    [Parameter(Mandatory)][string]$IpA,
    [Parameter(Mandatory)][string]$IpB,
    [Parameter(Mandatory)][string]$IpC,
    [int]$UiPort = 8080,
    [int]$PeerPort = 9080
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

function New-Secret([int]$Bytes) {
    $buffer = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return ([BitConverter]::ToString($buffer) -replace '-', '').ToLower()
}

$token = New-Secret 32
$ips = [ordered]@{ A = $IpA; B = $IpB; C = $IpC }
$labels = @{ A = 'Kino Bratislava'; B = 'Kino Košice'; C = 'Kino Žilina' }
New-Item -ItemType Directory -Force config/hosts | Out-Null

# Ak na jednom hostiteľovi beží viac uzlov (napr. A aj C na PC), ďalší dostane porty +100.
$ports = @{}
$perHost = @{}
foreach ($node in $ips.Keys) {
    $offset = 100 * [int]$perHost[$ips[$node]]
    $perHost[$ips[$node]] = [int]$perHost[$ips[$node]] + 1
    $ports[$node] = @{ Ui = $UiPort + $offset; Peer = $PeerPort + $offset }
}

foreach ($node in $ips.Keys) {
    $peers = ($ips.Keys | Where-Object { $_ -ne $node } | ForEach-Object { "$_=http://$($ips[$_]):$($ports[$_].Peer)" }) -join ','
    $lines = @(
        "# Uzol $node – hostiteľ $($ips[$node]). Vygenerované $(Get-Date -Format 'yyyy-MM-dd HH:mm')."
        "NODE_ID=$node"
        "NODE_LABEL=$($labels[$node])"
        "COMPOSE_PROJECT_NAME=dt-node-$($node.ToLower())"
        "UI_PORT=$($ports[$node].Ui)"
        "PEER_PORT=$($ports[$node].Peer)"
        "PEER_NODES=$peers"
        'APP_VERSION=1.0.0'
        "# Token musí byť rovnaký na všetkých uzloch; DB heslá sú lokálne pre uzol."
        "REPLICATION_TOKEN=$token"
        "DB_PASSWORD=$(New-Secret 16)"
        "DB_ROOT_PASSWORD=$(New-Secret 16)"
    )
    $path = "config/hosts/node-$($node.ToLower()).env"
    # LF konce riadkov – súbor sa použije aj na Linux VM
    [IO.File]::WriteAllText((Join-Path (Get-Location) $path), (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    Write-Host "$path  ->  UI http://$($ips[$node]):$($ports[$node].Ui)"
}
Write-Host "`nSkopírujte celý priečinok projektu (vrátane config/hosts) na každý hostiteľ a spustite tam deploy-node."
