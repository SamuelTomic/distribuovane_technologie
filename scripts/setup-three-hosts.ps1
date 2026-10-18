# Prepne nasadenie na 3 reálnych hostiteľov: A = tento PC, B = VirtualBox VM na tomto PC, C = počítač kamaráta.
# Použitie (na tomto PC, keď ste obaja v jednej sieti):
#   .\scripts\setup-three-hosts.ps1 -FriendIp 192.168.0.23
# Výsledok: config/hosts/node-c.env pošlite kamarátovi (súkromne – obsahuje replikačný token).
#
# Uzol B je v LAN dostupný cez tento PC (VirtualBox NAT port forwarding), takže netreba bridged sieť VM.
# Ak bridged adaptér VM dostal v sieti vlastnú IP (napr. na hotspote), zadajte ju cez -VmLanIp –
# uzol B potom vystupuje ako samostatný hostiteľ (port forwarding na niektorých sieťach nefunguje).
# Ak -FriendIp = IP tohto PC, uzol C sa spustí lokálne (simulácia bez kamaráta).
param(
    [Parameter(Mandatory)][string]$FriendIp,
    [string]$MyIp = '',
    [string]$VmName = 'dt-node-b',
    [string]$VmLanIp = '',
    [switch]$SkipFirewall
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$vbm = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'

if (-not $MyIp) {
    $MyIp = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.InterfaceAlias -notmatch 'vEthernet|VirtualBox' } |
        Select-Object -First 1).IPv4Address.IPAddress
    if (-not $MyIp) { throw 'Nepodarilo sa zistiť IP tohto PC – zadajte -MyIp.' }
}
$bIp = if ($VmLanIp) { $VmLanIp } else { $MyIp }
Write-Host "Tento PC: $MyIp   VM (uzol B): $bIp   Kamarátov PC: $FriendIp`n" -ForegroundColor Cyan

function Read-Env([string]$Path) {
    $values = @{}
    Get-Content $Path | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $values[$k] = $v.Trim() }
    return $values
}

# 1. Konfigurácia (token a DB heslá sa zachovajú)
& "$root\scripts\new-host-configs.ps1" -IpA $MyIp -IpB $bIp -IpC $FriendIp | Out-Null
$a = Read-Env config\hosts\node-a.env
$b = Read-Env config\hosts\node-b.env
$c = Read-Env config\hosts\node-c.env

# 2. Firewall tohto PC: A (UI + replikácia) a B (presmerované na VM). Vyžaduje administrátora – zobrazí sa UAC.
$ports = @($a.UI_PORT, $a.PEER_PORT)
if (-not $VmLanIp) { $ports += @($b.UI_PORT, $b.PEER_PORT) }
if ($FriendIp -eq $MyIp) { $ports += @($c.UI_PORT, $c.PEER_PORT) }
$missing = @($ports | Where-Object { -not (Get-NetFirewallRule -DisplayName "DT uzol $_" -ErrorAction SilentlyContinue) })
if ($missing -and -not $SkipFirewall) {
    Write-Host "Otváram porty vo Windows Firewalle: $($missing -join ', ') (potvrďte UAC okno)..."
    $cmd = ($missing | ForEach-Object { "New-NetFirewallRule -DisplayName 'DT uzol $_' -Direction Inbound -Protocol TCP -LocalPort $_ -Action Allow | Out-Null" }) -join '; '
    try { Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $cmd }
    catch { Write-Warning "Firewall sa nepodarilo nastaviť (UAC zamietnuté?). Kamarát sa nemusí pripojiť. Porty: $($missing -join ', ')" }
}

# 3. Uzol C na tomto PC: pri simulácii ho spustíme, inak zastavíme (beží u kamaráta)
$ErrorActionPreference = 'Continue'
if ($FriendIp -eq $MyIp) {
    & "$root\scripts\deploy-node.ps1" -EnvFile config\hosts\node-c.env | Out-Null
} else {
    docker compose -f docker-compose.node.yml --env-file config\hosts\node-c.env down 2>&1 | Out-Null
    Write-Host 'Lokálny uzol C zastavený (dáta ostávajú vo volume).'
}

# 4. Uzol A na tomto PC – nová konfigurácia peerov
& "$root\scripts\deploy-node.ps1" -EnvFile config\hosts\node-a.env | Out-Null
Write-Host "Uzol A: http://${MyIp}:$($a.UI_PORT)"

# 5. Uzol B na VM: presmerovanie portov z tohto PC na VM a nové nasadenie
if ((& $vbm list runningvms | Out-String) -notmatch [regex]::Escape("`"$VmName`"")) {
    & $vbm startvm $VmName --type headless | Out-Null
    Write-Host 'Štartujem VM...'
}
# Počkaj na SSH (VM po štarte alebo po resete sieťovky)
$knownHosts = "$HOME\VirtualBox VMs\$VmName\known_hosts"
for ($i = 0; $i -lt 30; $i++) {
    ssh.exe -i "$HOME\.ssh\dt_vm_ed25519" -o BatchMode=yes -o ConnectTimeout=5 -o "UserKnownHostsFile=$knownHosts" dt@192.168.56.20 true 2>$null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep 5
}
foreach ($rule in 'dt-ui', 'dt-peer', 'dt-agent') { & $vbm controlvm $VmName natpf1 delete $rule 2>$null | Out-Null }
if (-not $VmLanIp) {
    & $vbm controlvm $VmName natpf1 "dt-ui,tcp,,$($b.UI_PORT),,$($b.UI_PORT)"
    & $vbm controlvm $VmName natpf1 "dt-peer,tcp,,$($b.PEER_PORT),,$($b.PEER_PORT)"
    & $vbm controlvm $VmName natpf1 "dt-agent,tcp,,$($b.AGENT_PORT),,$($b.AGENT_PORT)"
}
$ErrorActionPreference = 'Stop'
& "$root\scripts\vm\deploy-to-vm.ps1" -VmName $VmName | Out-Null
Write-Host "Uzol B: http://${bIp}:$($b.UI_PORT)$(if (-not $VmLanIp) { '  (cez tento PC → VM)' })"

# 6. Centrálne logy: Dozzle UI na tomto PC pripojené na agentov všetkých troch uzlov
$agentPort = { param($cfg) if ($cfg.AGENT_PORT) { $cfg.AGENT_PORT } else { '7007' } }
# Agenti na tomto PC sú dostupní cez host.docker.internal (spojenie na vlastnú LAN IP blokuje firewall)
$agentHost = { param($ip) if ($ip -eq $MyIp) { 'host.docker.internal' } else { $ip } }
$env:DOZZLE_AGENTS = (@("$(& $agentHost $MyIp):$(& $agentPort $a)", "$(& $agentHost $bIp):$(& $agentPort $b)", "$(& $agentHost $FriendIp):$(& $agentPort $c)") | Select-Object -Unique) -join ','
$ErrorActionPreference = 'Continue'
docker compose -f docker-compose.monitoring.yml down 2>&1 | Out-Null
docker compose -f docker-compose.monitoring.yml up -d 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'
Write-Host "Centrálne logy: http://localhost:8099  (agenti: $env:DOZZLE_AGENTS)"

# 7. Kontrola
Write-Host "`nKontrola dostupnosti:" -ForegroundColor Cyan
foreach ($n in @(@('A', $MyIp, $a.UI_PORT), @('B', $bIp, $b.UI_PORT), @('C', $FriendIp, $c.UI_PORT))) {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 4 "http://$($n[1]):$($n[2])/health.php" | Out-Null; Write-Host "  $($n[0])  http://$($n[1]):$($n[2])  online" }
    catch { Write-Host "  $($n[0])  http://$($n[1]):$($n[2])  zatiaľ nedostupný" }
}
if ($FriendIp -ne $MyIp) {
    Write-Host "`nPošlite kamarátovi súbor config\hosts\node-c.env (súkromne, nie cez GitHub)." -ForegroundColor Yellow
    Write-Host "Kamarát ho uloží do config\hosts\ a spustí: .\scripts\deploy-node.ps1 -EnvFile config\hosts\node-c.env -OpenFirewall"
}
