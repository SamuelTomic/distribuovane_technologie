# Prompt pre Claude Code na počítači s uzlom C

Tento text vlož do Claude Code na druhom počítači. Spolu s ním pošli súkromne súbor `node-c.env`
(vygeneruje ho `scripts/setup-three-hosts.ps1 -FriendIp <IP>`). IP adresy nižšie zodpovedajú
konkrétnej sieti (A a B na `192.168.0.103`, C na `192.168.0.100`), pri inej sieti ich uprav.

```text
Pomôž mi spustiť uzol C distribuovaného systému na tomto počítači (Windows) a over, že komunikuje s ostatnými uzlami.

## Kontext

Školský projekt (Distribuované technológie, variant 2): distribuovaná evidencia porúch kín v Docker kontajneroch.
Systém má tri uzly, ktoré si cez HTTP replikujú záznamy:

- Uzol A – Filipov PC, IP 192.168.0.103, porty 8080 (UI) a 9080 (replikácia)
- Uzol B – virtuálny stroj na Filipovom PC, dostupný cez 192.168.0.103, porty 8180 (UI) a 9180 (replikácia)
- Uzol C – TENTO počítač (IP by mala byť 192.168.0.100), porty 8080 (UI) a 9080 (replikácia)

Repozitár: https://github.com/SamuelTomic/distribuovane_technologie
Každý uzol tvoria 4 kontajnery: web (nginx), app (PHP + REST API), worker (synchronizácia) a db (MySQL s vlastným volume).
Nasadenie jedného uzla definuje docker-compose.node.yml a konfiguračný súbor uzla config/hosts/node-c.env.

Súbor node-c.env mi poslal Filip (pravdepodobne je v Stiahnutých súboroch alebo na ploche). Obsahuje tajný replikačný token.

## Postup

1. Over, že beží Docker Desktop: `docker version` musí vypísať aj Server.
   Ak Docker nie je nainštalovaný alebo nebeží, zastav sa a povedz mi, čo mám urobiť
   (inštalácia z https://www.docker.com/products/docker-desktop/, potom ho spustiť).

2. Naklonuj repozitár do Documents (ak tam ešte nie je):
   `git clone https://github.com/SamuelTomic/distribuovane_technologie.git`
   Ak git chýba, povedz mi, nech stiahnem ZIP z GitHubu.

3. Nájdi súbor node-c.env, ktorý mi poslal Filip, a skopíruj ho do
   `distribuovane_technologie\config\hosts\node-c.env` (priečinok vytvor, ak neexistuje).
   Skontroluj, že sa nevolá node-c.env.txt a že obsahuje:
   NODE_ID=C, UI_PORT=8080, PEER_PORT=9080, PEER_NODES=A=http://192.168.0.103:9080,B=http://192.168.0.103:9180
   Do výstupu NEVYPISUJ hodnoty REPLICATION_TOKEN ani hesiel.

4. Over moju IP adresu (`ipconfig`, IPv4 adaptéra Wi-Fi/Ethernet). Ak nie je 192.168.0.100, zapamätaj si ju –
   Filip musí na svojej strane spustiť setup s touto IP (povedz mi to na konci).

5. Over spojenie s Filipovým PC:
   `Test-NetConnection 192.168.0.103 -Port 9080` a `Test-NetConnection 192.168.0.103 -Port 9180`
   Obe musia mať TcpTestSucceeded : True. Ak nie, nie sme v rovnakej sieti alebo Filipove uzly nebežia – zastav sa a povedz mi to.

6. Otvor porty vo Windows Firewalle, aby sa uzly A a B dostali ku mne. Vyžaduje to administrátora.
   Ak nie si spustený ako administrátor, použi UAC (ja potvrdím okno):
   Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command',"New-NetFirewallRule -DisplayName 'DT uzol 8080' -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow; New-NetFirewallRule -DisplayName 'DT uzol 9080' -Direction Inbound -Protocol TCP -LocalPort 9080 -Action Allow"
   Potom over, že pravidlá existujú: Get-NetFirewallRule -DisplayName 'DT uzol*'

7. Spusti uzol C (z priečinka projektu):
   `powershell -ExecutionPolicy Bypass -File .\scripts\deploy-node.ps1 -EnvFile config\hosts\node-c.env`
   Prvé spustenie trvá niekoľko minút (sťahuje MySQL, PHP, nginx a zostavuje image).
   Na konci musí vypísať A ... online a B ... online.

8. Over, že všetko funguje:
   - `docker compose -f docker-compose.node.yml --env-file config\hosts\node-c.env ps` – 4 kontajnery (db, app, worker, web) healthy
   - http://localhost:8080/api/status – node_id "C", v "peers" majú A aj B "reachable": true
   - http://192.168.0.103:8080/api/status – Filipov uzol A, v "peers" má C "reachable": true
     (ak je false, Filipove uzly sa ku mne nedostanú – skontroluj firewall z kroku 6)
   - Počet záznamov ("records") a "manifest_hash" v /api/status mojho uzla C a uzla A sú rovnaké
     (synchronizácia môže trvať do ~15 sekúnd)

9. Na záver mi napíš:
   - či uzol beží a vidí A aj B, a či A vidí mňa,
   - moju IP adresu,
   - že môžem otvoriť http://localhost:8080 a Filip môže spustiť test obhajoby (scripts\vm\defense-vm.ps1).

## Pravidlá

- Nemeň zdrojový kód projektu ani hodnoty NODE_ID, REPLICATION_TOKEN a PEER_NODES v node-c.env.
  Ak niečo nesedí (iná IP, obsadený port), povedz mi to – Filip vygeneruje nový súbor.
- node-c.env nikdy necommituj ani nikam nenahrávaj (je v .gitignore).
- Nepoužívaj `docker compose down -v` (zmazalo by to databázu uzla).
- Ak je port 8080 alebo 9080 obsadený inou aplikáciou, nezastavuj ju bez môjho súhlasu – povedz mi, čo port používa.

## Užitočné príkazy

- Logy synchronizácie: docker compose -f docker-compose.node.yml --env-file config\hosts\node-c.env logs -f worker
- Zastavenie / spustenie: ... stop / ... start (s rovnakými parametrami -f a --env-file)
```
