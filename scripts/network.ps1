# Simulácia výpadku uzla v lokálnom clusteri: odpojí/pripojí app + worker uzla od replikačnej siete.
# Uzol beží ďalej (UI na svojom porte funguje), iba nevidí ostatné uzly.
# Použitie: .\scripts\network.ps1 -Node B -Action disconnect
#           .\scripts\network.ps1 -Node B -Action connect
param(
    [Parameter(Mandatory)][ValidateSet('A', 'B', 'C')][string]$Node,
    [Parameter(Mandatory)][ValidateSet('disconnect', 'connect')][string]$Action
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$network = 'dt-replication'
foreach ($role in 'app', 'worker') {
    $service = "node-$($Node.ToLower())-$role"
    $container = (docker compose ps -q $service).Trim()
    if (-not $container) { throw "Kontajner $service nebeží." }

    $attached = (docker inspect -f "{{range `$k, `$v := .NetworkSettings.Networks}}{{`$k}} {{end}}" $container) -split ' ' -contains $network
    if ($Action -eq 'disconnect' -and $attached) {
        docker network disconnect $network $container
    } elseif ($Action -eq 'connect' -and -not $attached) {
        # Alias = názov služby, aby ho ostatné uzly znova našli cez DNS.
        docker network connect --alias $service $network $container
    }
    Write-Host "$service -> $Action"
}
