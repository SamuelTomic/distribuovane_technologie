# Scenár obhajoby pre nasadenie na viac hostiteľov: uzol B beží na Linux VM,
# odpojenie (iptables), pripojenie a reštart uzla B sa robia automaticky cez SSH.
# Použitie: .\scripts\vm\defense-vm.ps1 [-VmIp 192.168.56.20]
param(
    [string]$VmIp = '192.168.56.20',
    [string]$VmName = 'dt-node-b',
    [string]$SshKey = "$HOME\.ssh\dt_vm_ed25519"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $root

function Read-NodeConfig([string]$Node) {
    $config = @{}
    Get-Content "config\hosts\node-$Node.env" | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $config[$k] = $v }
    return $config
}
$a = Read-NodeConfig a
$b = Read-NodeConfig b
$c = Read-NodeConfig c
# Adresy uzlov A a C zistí z PEER_NODES uzla B, porty UI z ich konfigurácie.
$peerHost = @{}
foreach ($entry in $b.PEER_NODES -split ',') { $n, $url = $entry -split '=', 2; $peerHost[$n] = ([Uri]$url).Host }

$knownHosts = "$HOME\VirtualBox VMs\$VmName\known_hosts"
$ssh = "ssh.exe -i `"$SshKey`" -o BatchMode=yes -o ConnectTimeout=10 -o `"UserKnownHostsFile=$knownHosts`" dt@$VmIp"
$compose = 'docker compose -f docker-compose.node.yml --env-file config/hosts/node-b.env'

& "$root\tests\defense.ps1" `
    -A "http://$($peerHost.A):$($a.UI_PORT)" `
    -B "http://${VmIp}:$($b.UI_PORT)" `
    -C "http://$($peerHost.C):$($c.UI_PORT)" `
    -Token $a.REPLICATION_TOKEN `
    -DisconnectCommand "$ssh 'cd dt-projekt && sudo sh scripts/partition.sh on config/hosts/node-b.env'" `
    -ConnectCommand "$ssh 'cd dt-projekt && sudo sh scripts/partition.sh off config/hosts/node-b.env'" `
    -RestartCommand "$ssh 'cd dt-projekt && $compose restart'" `
    -TimeoutSeconds 120
exit $LASTEXITCODE
