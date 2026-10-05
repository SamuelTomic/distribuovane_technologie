# Simulácia výpadku uzla na Windows hostiteľovi (Docker Desktop) – spúšťať ako administrátor.
# Zablokuje replikačný port (prichádzajúci aj odchádzajúci) vo Windows Firewalle; UI ostáva dostupné.
# Odporúčanie: na obhajobe odpájajte uzol B bežiaci na Linux VM (scripts/partition.sh) – to je overené.
#   .\scripts\partition.ps1 -Action on  -EnvFile config\hosts\node-a.env
#   .\scripts\partition.ps1 -Action off -EnvFile config\hosts\node-a.env
param(
    [Parameter(Mandatory)][ValidateSet('on', 'off')][string]$Action,
    [Parameter(Mandatory)][string]$EnvFile
)
$ErrorActionPreference = 'Stop'
$peerPort = ((Get-Content $EnvFile | Where-Object { $_ -match '^PEER_PORT=' }) -replace '^PEER_PORT=', '').Trim()
if (-not $peerPort) { $peerPort = '9080' }
$name = 'DT partition'

Get-NetFirewallRule -DisplayName "$name*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Action -eq 'on') {
    New-NetFirewallRule -DisplayName "$name in" -Direction Inbound -Protocol TCP -LocalPort $peerPort -Action Block | Out-Null
    New-NetFirewallRule -DisplayName "$name out" -Direction Outbound -Protocol TCP -RemotePort $peerPort -Action Block | Out-Null
    Write-Host "Uzol odpojený od replikácie (port $peerPort blokovaný)."
} else {
    Write-Host 'Replikácia znova povolená.'
}
