# Automaticky vytvorí VirtualBox VM s Ubuntu 24.04 + Docker pre jeden uzol (bez ručnej inštalácie).
# Použitie: .\scripts\vm\create-virtualbox-vm.ps1 [-Name dt-node-b] [-Ip 192.168.56.20] [-Recreate]
#
# Sieť VM:
#   nic1 NAT          – internet (apt, Docker image)
#   nic2 host-only    – statická IP $Ip, spoľahlivé spojenie PC <-> VM (192.168.56.0/24)
#   nic3 bridged      – IP z LAN (DHCP), aby VM videl aj iný počítač v sieti
# Prihlásenie: ssh -i ~/.ssh/dt_vm_ed25519 dt@$Ip   (konzola VM: dt / dt-projekt)
param(
    [string]$Name = 'dt-node-b',
    [string]$Ip = '192.168.56.20',
    [int]$MemoryMB = 3072,
    [int]$Cpus = 2,
    [int]$DiskGB = 30,
    [string]$HostOnlyAdapter = 'VirtualBox Host-Only Ethernet Adapter',
    [string]$BridgeAdapter = '',
    [string]$SshKey = "$HOME\.ssh\dt_vm_ed25519",
    [switch]$Recreate
)
$ErrorActionPreference = 'Stop'
$vbm = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $vbm)) { throw 'VirtualBox nie je nainštalovaný.' }
$vmDir = Join-Path "$HOME\VirtualBox VMs" $Name
$image = Join-Path $vmDir 'noble-server-cloudimg-amd64.vmdk'
$disk = Join-Path $vmDir "$Name.vdi"
$seedDir = Join-Path $vmDir 'seed'
$noBom = New-Object Text.UTF8Encoding $false

function VBox { & $vbm @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') zlyhal" } }
function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $noBom) }

# --- existujúca VM ---------------------------------------------------------
$exists = (& $vbm list vms) -match "^`"$Name`""
if ($exists) {
    if (-not $Recreate) { throw "VM $Name už existuje (použite -Recreate na nové vytvorenie)." }
    & $vbm controlvm $Name poweroff 2>$null | Out-Null
    Start-Sleep 3
    VBox unregistervm $Name --delete
}
New-Item -ItemType Directory -Force $vmDir, $seedDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $disk, (Join-Path $vmDir 'known_hosts')

# --- Ubuntu cloud image ------------------------------------------------------
if (-not (Test-Path $image)) {
    Write-Host 'Sťahujem Ubuntu 24.04 cloud image...'
    curl.exe -fSL --retry 3 -o $image https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.vmdk
}
$sums = (curl.exe -fsSL https://cloud-images.ubuntu.com/noble/current/SHA256SUMS) -split "`n"
$expected = (($sums | Where-Object { $_ -match 'noble-server-cloudimg-amd64\.vmdk$' }) -split ' ')[0]
$actual = (Get-FileHash $image -Algorithm SHA256).Hash.ToLower()
if ($expected -and $expected -ne $actual) { throw "Kontrolný súčet image nesedí ($actual). Zmažte $image a skúste znova." }

# --- SSH kľúč ------------------------------------------------------------------
if (-not (Test-Path $SshKey)) { ssh-keygen -q -t ed25519 -N '""' -C 'dt-projekt-vm' -f $SshKey }
$publicKey = (Get-Content "$SshKey.pub" -Raw).Trim()

# --- cloud-init (NoCloud seed ISO) -------------------------------------------
Write-Lf (Join-Path $seedDir 'meta-data') "instance-id: $Name-$(Get-Date -Format yyyyMMddHHmmss)`nlocal-hostname: $Name`n"
Write-Lf (Join-Path $seedDir 'user-data') @"
#cloud-config
hostname: $Name
users:
  - name: dt
    gecos: DT projekt
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - $publicKey
chpasswd:
  expire: false
  users:
    - { name: dt, password: dt-projekt, type: text }
ssh_pwauth: false
package_update: true
packages: [docker.io, docker-compose-v2, conntrack, curl]
runcmd:
  - usermod -aG docker dt
  - systemctl enable --now docker
  - touch /var/lib/dt-ready
"@
Write-Lf (Join-Path $seedDir 'network-config') @"
version: 2
ethernets:
  nat:
    match: { macaddress: "08:00:27:d7:00:01" }
    dhcp4: true
  hostonly:
    match: { macaddress: "08:00:27:d7:00:02" }
    dhcp4: false
    addresses: [$Ip/24]
  lan:
    match: { macaddress: "08:00:27:d7:00:03" }
    dhcp4: true
    optional: true
    dhcp4-overrides: { route-metric: 200 }
"@
Write-Host 'Vytváram cloud-init seed ISO (cez Docker kontajner)...'
docker run --rm -v "${seedDir}:/seed" alpine:3.20 sh -c 'apk add --no-cache -q xorriso >/dev/null && xorriso -as mkisofs -quiet -o /seed/seed.iso -V cidata -J -R /seed/user-data /seed/meta-data /seed/network-config'
if ($LASTEXITCODE -ne 0) { throw 'Vytvorenie seed ISO zlyhalo (beží Docker Desktop?).' }

# --- disk ------------------------------------------------------------------------
Write-Host 'Pripravujem disk...'
VBox clonemedium disk $image $disk --format VDI | Out-Null
VBox modifymedium disk $disk --resize ($DiskGB * 1024) | Out-Null

# --- VM --------------------------------------------------------------------------
if (-not $BridgeAdapter) {
    $bridged = (& $vbm list bridgedifs) -join "`n" -split "`n`n" | Where-Object { $_ -match 'Status:\s+Up' -and $_ -notmatch 'Hyper-V|VirtualBox' }
    $BridgeAdapter = ($bridged | Select-Object -First 1) -replace '(?s)^Name:\s+([^\r\n]+).*', '$1'
}
Write-Host "Vytváram VM $Name (bridged: $BridgeAdapter)..."
VBox createvm --name $Name --ostype Ubuntu_64 --register --basefolder "$HOME\VirtualBox VMs" | Out-Null
VBox modifyvm $Name --memory $MemoryMB --cpus $Cpus --ioapic on --firmware bios --graphicscontroller vmsvga --vram 16 `
    --audio-enabled off --usb off --boot1 disk --boot2 dvd --boot3 none --boot4 none `
    --nic1 nat --macaddress1 080027D70001 --natpf1 'ssh,tcp,127.0.0.1,2222,,22' `
    --nic2 hostonly --hostonlyadapter2 $HostOnlyAdapter --macaddress2 080027D70002 `
    --uart1 0x3F8 4 --uartmode1 file (Join-Path $vmDir 'serial.log')
if ($BridgeAdapter) { VBox modifyvm $Name --nic3 bridged --bridgeadapter3 $BridgeAdapter --macaddress3 080027D70003 }
VBox storagectl $Name --name SATA --add sata --controller IntelAhci --portcount 2
VBox storageattach $Name --storagectl SATA --port 0 --device 0 --type hdd --medium $disk
VBox storageattach $Name --storagectl SATA --port 1 --device 0 --type dvddrive --medium (Join-Path $seedDir 'seed.iso')

VBox startvm $Name --type headless | Out-Null
Write-Host "VM štartuje, čakám na SSH a inštaláciu Dockera (prvé spustenie trvá niekoľko minút)..."

$knownHosts = Join-Path $vmDir 'known_hosts'
$sshArgs = @('-i', $SshKey, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$knownHosts", "dt@$Ip")
$deadline = (Get-Date).AddMinutes(20)
$ready = $false
$ErrorActionPreference = 'Continue'
while ((Get-Date) -lt $deadline) {
    $out = & ssh.exe @sshArgs 'test -f /var/lib/dt-ready && sudo docker version --format "{{.Server.Version}}"' 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { $ready = $true; break }
    Start-Sleep 10
}
$ErrorActionPreference = 'Stop'
if (-not $ready) { throw "VM sa nepodarilo pripraviť do 20 minút. Pozrite $vmDir\serial.log" }

Write-Host "`nVM $Name je pripravená. Docker $out"
Write-Host "  SSH:      ssh -i $SshKey -o UserKnownHostsFile=`"$knownHosts`" dt@$Ip"
Write-Host "  Konzola:  dt / dt-projekt"
Write-Host "  IP:       $((& ssh.exe @sshArgs 'hostname -I') -join ' ')"
