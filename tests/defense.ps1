# Automatizovaný scenár obhajoby (10 krokov zo zadania).
#
# Lokálne (3 uzly na jednom PC – odpojenie aj reštart robí skript sám):
#   powershell -ExecutionPolicy Bypass -File .\tests\defense.ps1
#
# Viac počítačov / VM (odpojenie a reštart uzla B urobíte ručne, skript počká):
#   powershell -ExecutionPolicy Bypass -File .\tests\defense.ps1 -Manual `
#       -A http://192.168.56.101:8080 -B http://192.168.56.102:8080 -C http://192.168.56.103:8080 -Token <REPLICATION_TOKEN>
#
# Uzol B na Linux VM, odpojenie/reštart automaticky cez SSH: pozri scripts/vm/defense-vm.ps1
param(
    [string]$A = 'http://localhost:8081',
    [string]$B = 'http://localhost:8082',
    [string]$C = 'http://localhost:8083',
    [string]$Token = '',
    [switch]$Manual,
    # Príkazy pre vzdialený uzol B (napr. cez SSH) – nahradia ručné kroky v režime -Manual.
    [string]$DisconnectCommand = '',
    [string]$ConnectCommand = '',
    [string]$RestartCommand = '',
    [int]$TimeoutSeconds = 90
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$Nodes = [ordered]@{ A = $A.TrimEnd('/'); B = $B.TrimEnd('/'); C = $C.TrimEnd('/') }
if (-not $Token -and (Test-Path .env)) {
    $Token = ((Get-Content .env | Where-Object { $_ -match '^REPLICATION_TOKEN=' }) -replace '^REPLICATION_TOKEN=', '').Trim()
}
if (-not $Token) { throw 'Chýba replikačný token (-Token alebo .env).' }

$script:passed = 0
$script:failed = 0

function Invoke-Api([string]$Method, [string]$Url, $Body = $null, [switch]$Peer) {
    $headers = @{ Accept = 'application/json' }
    if ($Method -ne 'GET') { $headers['X-Requested-With'] = 'dt-ui' }
    if ($Peer) { $headers['X-Replication-Token'] = $Token; $headers['X-Node-Id'] = 'TEST' }
    $params = @{ Method = $Method; Uri = $Url; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($null -ne $Body) {
        $params['ContentType'] = 'application/json; charset=utf-8'
        $params['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
    }
    try {
        $response = Invoke-WebRequest @params
        return @{ Status = [int]$response.StatusCode; Data = ($response.Content | ConvertFrom-Json) }
    } catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $data = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { try { $data = $_.ErrorDetails.Message | ConvertFrom-Json } catch { } }
        return @{ Status = $status; Data = $data; Error = $_.Exception.Message }
    }
}

function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++; Write-Host "  [OK]   $Message" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $Message" -ForegroundColor Red }
}

function Step([string]$Title) { Write-Host "`n=== $Title ===" -ForegroundColor Cyan }

function Get-Status([string]$Node) { (Invoke-Api GET "$($Nodes[$Node])/api/status").Data }

function New-Record([string]$Node, [string]$Hall, [string]$Text) {
    $result = Invoke-Api POST "$($Nodes[$Node])/api/records" @{ cislo_saly = $Hall; popis = $Text }
    if ($result.Status -ne 201) { throw "Vytvorenie záznamu na $Node zlyhalo: $($result.Error)" }
    return $result.Data.record
}

function Test-HasRecord([string]$Node, [string]$Id, [int]$Version = 1) {
    $result = Invoke-Api GET "$($Nodes[$Node])/api/records/$Id"
    return $result.Status -eq 200 -and $result.Data.record.version -ge $Version
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds = $TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return $true } } catch { }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

function Test-Consistent {
    $statuses = foreach ($node in $Nodes.Keys) { Get-Status $node }
    if (@($statuses | Where-Object { $null -eq $_ }).Count -gt 0) { return $false }
    $hashes = @($statuses | ForEach-Object { $_.manifest_hash } | Select-Object -Unique)
    $pending = ($statuses | ForEach-Object { $_.outbox.pending } | Measure-Object -Sum).Sum
    return $hashes.Count -eq 1 -and $pending -eq 0
}

function Invoke-External([string]$Command) {
    Write-Host "  > $Command" -ForegroundColor DarkGray
    $ErrorActionPreference = 'Continue'
    Invoke-Expression $Command 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    $ErrorActionPreference = 'Stop'
}

function Set-NodeB([string]$Action) {
    $command = if ($Action -eq 'disconnect') { $DisconnectCommand } else { $ConnectCommand }
    if ($command) {
        Invoke-External $command
    } elseif ($Manual) {
        Read-Host "  >>> Teraz $(if ($Action -eq 'disconnect') { 'ODPOJTE' } else { 'PRIPOJTE' }) uzol B od siete a stlačte Enter"
    } else {
        & "$root\scripts\network.ps1" -Node B -Action $Action | Out-Null
    }
}

# 1. ---------------------------------------------------------------
Step '1. Spustenie uzlov A, B, C'
foreach ($node in $Nodes.Keys) {
    $status = Get-Status $node
    Check ($null -ne $status -and $status.db -eq 'ok' -and $status.worker.alive) "uzol $node beží ($($Nodes[$node])), DB ok, worker beží"
}
Check (Wait-Until { Test-Consistent } 30) 'výchozí stav je konzistentný'

# 2. ---------------------------------------------------------------
Step '2. Vytvorenie údaja na A a jeho replikácia'
$r1 = New-Record A 'S1' "Test obhajoby – záznam z A ($(Get-Date -Format HH:mm:ss))"
Write-Host "  vytvorený $($r1.id)"
Check (Wait-Until { (Test-HasRecord B $r1.id) -and (Test-HasRecord C $r1.id) } 20) 'záznam z A je na B aj C'

# 3. ---------------------------------------------------------------
Step '3. Odpojenie uzla B'
Set-NodeB disconnect
Check (Wait-Until { -not ((Get-Status A).peers | Where-Object { $_.node_id -eq 'B' }).reachable } 20) 'A eviduje uzol B ako nedostupný'

# 4. ---------------------------------------------------------------
Step '4. Rozdielne údaje na A aj B počas výpadku'
$r2 = New-Record A 'S2' 'Počas výpadku – vytvorené na A'
$upd = Invoke-Api PUT "$($Nodes.A)/api/records/$($r1.id)" @{ stav = 'riesi_sa' }
Check ($upd.Status -eq 200 -and $upd.Data.record.version -eq 2) 'A upravil vlastný záznam (verzia 2)'
$r3 = New-Record B 'S3' 'Počas výpadku – vytvorené na B'
$r4 = New-Record B 'S4' 'Počas výpadku – na B vytvorené a zmazané'
$del = Invoke-Api DELETE "$($Nodes.B)/api/records/$($r4.id)"
Check ($del.Status -eq 200 -and $del.Data.record.deleted_at) 'B zmazal vlastný záznam (tombstone)'
$foreign = Invoke-Api PUT "$($Nodes.B)/api/records/$($r1.id)" @{ stav = 'vyriesena' }
Check ($foreign.Status -eq 403) 'B nemôže upraviť cudzí záznam (vlastník je A) → 403'
Check (-not (Test-HasRecord B $r2.id)) 'nový záznam z A na B zatiaľ nie je'
Check ((Get-Status B).outbox.pending -gt 0) "B má neodoslané operácie v outboxe: $((Get-Status B).outbox.pending)"

# 5. ---------------------------------------------------------------
Step '5. Synchronizácia počas výpadku musí bezpečne zlyhať'
$pendingBefore = (Get-Status B).outbox.pending
$syncB = Invoke-Api POST "$($Nodes.B)/api/sync"
Check ($syncB.Status -eq 503 -and $syncB.Data.ok -eq $false) "B /api/sync → HTTP $($syncB.Status), ok=false"
$syncA = Invoke-Api POST "$($Nodes.A)/api/sync"
Check ($syncA.Status -eq 503 -and $syncA.Data.peers.B.ok -eq $false) "A /api/sync → HTTP $($syncA.Status), B: $($syncA.Data.peers.B.error)"
Check ((Get-Status B).outbox.pending -eq $pendingBefore) 'žiadna operácia sa nestratila (outbox B nezmenený)'

# 6. ---------------------------------------------------------------
Step '6. Obnovenie spojenia'
Set-NodeB connect
$started = Get-Date

# 7. ---------------------------------------------------------------
Step '7. Doplnenie všetkých chýbajúcich operácií'
Check (Wait-Until { Test-Consistent }) "uzly sa zosynchronizovali za $([int]((Get-Date) - $started).TotalSeconds) s"
foreach ($node in $Nodes.Keys) {
    $ok = (Test-HasRecord $node $r1.id 2) -and (Test-HasRecord $node $r2.id) -and (Test-HasRecord $node $r3.id) -and (Test-HasRecord $node $r4.id 2)
    $tomb = (Invoke-Api GET "$($Nodes[$node])/api/records/$($r4.id)").Data.record.deleted_at
    Check ($ok -and $tomb) "uzol $node má všetky 4 záznamy, úpravu (v2) aj tombstone"
}

# 8. ---------------------------------------------------------------
Step '8. Opakovaná synchronizácia – žiadne duplicity'
$before = foreach ($node in $Nodes.Keys) { Get-Status $node }
for ($i = 1; $i -le 3; $i++) {
    foreach ($node in $Nodes.Keys) { Invoke-Api POST "$($Nodes[$node])/api/sync" | Out-Null }
}
$after = foreach ($node in $Nodes.Keys) { Get-Status $node }
for ($i = 0; $i -lt 3; $i++) {
    Check ($after[$i].records.total -eq $before[$i].records.total -and $after[$i].manifest_hash -eq $before[$i].manifest_hash) `
        "uzol $($after[$i].node_id): po 3× sync rovnaký počet ($($after[$i].records.total)) aj manifest"
}
# Priame opakované doručenie tej istej operácie (at-least-once) – musí byť rozpoznané ako duplicita.
$record = (Invoke-Api GET "$($Nodes.A)/api/records/$($r2.id)").Data.record
$opId = [guid]::NewGuid().ToString()
$results = for ($i = 0; $i -lt 3; $i++) {
    $resp = Invoke-WebRequest -UseBasicParsing -Method POST -Uri "$($Nodes.C)/api/replicate" `
        -Headers @{ 'X-Replication-Token' = $Token; 'X-Node-Id' = 'A' } -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes((@{ from_node = 'A'; ops = @(@{ op_id = $opId; op_type = 'UPDATE'; record = $record }) } | ConvertTo-Json -Depth 10 -Compress)))
    (($resp.Content | ConvertFrom-Json).results[0]).status
}
Check ($results[1] -eq 'duplicate' -and $results[2] -eq 'duplicate') "3× doručená operácia na C: $($results -join ', ')"
Check ((Get-Status C).records.total -eq $after[2].records.total) 'počet záznamov na C sa nezmenil'

# 9. ---------------------------------------------------------------
Step '9. Porovnanie manifestov, počtov, ID, verzií a kontrolných súčtov'
$manifests = [ordered]@{}
foreach ($node in $Nodes.Keys) { $manifests[$node] = (Invoke-Api GET "$($Nodes[$node])/api/manifest" -Peer).Data }
$table = foreach ($node in $Nodes.Keys) {
    $m = $manifests[$node]
    $integrity = (Invoke-Api GET "$($Nodes[$node])/api/integrity").Data.ok
    [pscustomobject]@{ Uzol = $node; Zaznamy = $m.count; Aktivne = $m.active; Zmazane = $m.deleted; Manifest = $m.hash.Substring(0, 16); Integrita = $integrity }
}
$table | Format-Table -AutoSize | Out-String | Write-Host
$reference = ($manifests.A.records | ForEach-Object { "$($_.id):$($_.version):$($_.checksum)" }) -join "`n"
foreach ($node in 'B', 'C') {
    $other = ($manifests[$node].records | ForEach-Object { "$($_.id):$($_.version):$($_.checksum)" }) -join "`n"
    Check ($other -eq $reference) "manifest $node = manifest A (ID, verzie, checksumy)"
}
Check (@($table | Where-Object { -not $_.Integrita }).Count -eq 0) 'kontrolné súčty všetkých uložených záznamov sedia'

# 10. --------------------------------------------------------------
Step '10. Reštart uzla a zachovanie údajov'
$hashBefore = (Get-Status B).manifest_hash
if ($RestartCommand) {
    Invoke-External $RestartCommand
} elseif ($Manual) {
    Read-Host '  >>> Reštartujte uzol B (napr. docker compose -f docker-compose.node.yml restart) a stlačte Enter'
} else {
    $ErrorActionPreference = 'Continue'   # docker píše priebeh na stderr
    docker compose restart node-b-db node-b-app node-b-worker 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
}
Check (Wait-Until { (Get-Status B).worker.alive } 120) 'uzol B po reštarte znova beží (app + worker)'
$statusB = Get-Status B
Check ($statusB.manifest_hash -eq $hashBefore) "uzol B po reštarte má rovnaké dáta ($($statusB.records.total) záznamov, rovnaký manifest)"

Write-Host "`nVýsledok: $script:passed OK, $script:failed FAIL" -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
if ($script:failed) { exit 1 }
