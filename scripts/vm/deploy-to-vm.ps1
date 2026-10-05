# Skopíruje projekt na Linux VM cez SSH a nasadí tam uzol (docker compose).
# Použitie: .\scripts\vm\deploy-to-vm.ps1 [-Ip 192.168.56.20] [-EnvFile config\hosts\node-b.env]
param(
    [string]$Ip = '192.168.56.20',
    [string]$EnvFile = 'config\hosts\node-b.env',
    [string]$VmName = 'dt-node-b',
    [string]$SshKey = "$HOME\.ssh\dt_vm_ed25519",
    [string]$RemoteDir = 'dt-projekt'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $root
if (-not (Test-Path $EnvFile)) { throw "Chýba $EnvFile – vygenerujte ho cez scripts\new-host-configs.ps1" }

$knownHosts = Join-Path "$HOME\VirtualBox VMs\$VmName" 'known_hosts'
$sshOpts = @('-i', $SshKey, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$knownHosts")
$target = "dt@$Ip"
$envName = Split-Path $EnvFile -Leaf

# Archív bez gitu, archívu, lokálnych tajomstiev a konfigurácií iných uzlov.
$archive = Join-Path $env:TEMP "dt-projekt-$VmName.tgz"
$excludes = @('--exclude=./.git', '--exclude=./_archive', '--exclude=./.env')
Get-ChildItem config\hosts -Filter '*.env' | Where-Object { $_.Name -ne $envName } | ForEach-Object { $excludes += "--exclude=./config/hosts/$($_.Name)" }
Write-Host "Balím projekt -> $archive"
tar.exe -czf $archive @excludes -C $root .
if ($LASTEXITCODE -ne 0) { throw 'tar zlyhal' }

Write-Host "Kopírujem na $target..."
scp.exe @sshOpts $archive "${target}:/tmp/dt-projekt.tgz"
if ($LASTEXITCODE -ne 0) { throw 'scp zlyhal' }
Remove-Item $archive

$remoteEnv = "config/hosts/$envName"
$remote = "set -e; mkdir -p ~/$RemoteDir; tar -xzf /tmp/dt-projekt.tgz -C ~/$RemoteDir; rm /tmp/dt-projekt.tgz; " +
          "cd ~/$RemoteDir; sh scripts/deploy-node.sh $remoteEnv"
Write-Host "Nasadzujem uzol na VM (prvý build image trvá pár minút)..."
$ErrorActionPreference = 'Continue'
ssh.exe @sshOpts $target $remote 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw 'Nasadenie na VM zlyhalo.' }
