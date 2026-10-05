# Návod: spustenie uzla C na druhom počítači

Celý systém má tri uzly na troch počítačoch:

| Uzol | Kde beží | Adresa |
|---|---|---|
| A | Filipov PC | `http://<IP Filipa>:8080` |
| B | virtuálny stroj na Filipovom PC | `http://<IP Filipa>:8180` |
| **C** | **tvoj počítač** | `http://localhost:8080` |

Uzly si medzi sebou posielajú záznamy cez sieť. Preto musíte byť obaja **v rovnakej sieti**
(rovnaká Wi-Fi, prípadne hotspot z mobilu).

## Čo potrebuješ

* Windows 10/11 s nainštalovaným **Docker Desktop** (https://www.docker.com/products/docker-desktop/).
  Po inštalácii ho spusti a počkaj, kým ikona veľryby v lište hlási „Engine running“.
* **Git** (https://git-scm.com/download/win) alebo projekt stiahnutý ako ZIP z GitHubu.
* Asi 3 GB voľného miesta (Docker image + databáza).

## Postup

### 1. Zisti svoju IP adresu a pošli ju Filipovi

V PowerShelli spusti:

```powershell
ipconfig
```

Pri adaptéri **Wi-Fi** (alebo Ethernet) nájdi riadok **IPv4 Address**, napr. `192.168.0.23`, a pošli ho Filipovi.

### 2. Stiahni projekt

```powershell
cd $HOME\Documents
git clone https://github.com/SamuelTomic/distribuovane_technologie.git
cd distribuovane_technologie
```

### 3. Ulož si konfiguračný súbor od Filipa

Filip ti pošle súbor **`node-c.env`**, napríklad cez Discord alebo USB. Na GitHube nie je, lebo obsahuje
tajný replikačný token. Ulož ho do priečinka projektu ako:

```
distribuovane_technologie\config\hosts\node-c.env
```

### 4. Over, že vidíš Filipov počítač

```powershell
Test-NetConnection <IP Filipa> -Port 9080
```

Riadok `TcpTestSucceeded : True` znamená, že spojenie funguje. Ak vidíš `False`, pozri časť
[Keď niečo nejde](#keď-niečo-nejde).

### 5. Spusti uzol C

Otvor **PowerShell ako správca** (pravý klik → *Spustiť ako správca*). Je to potrebné, aby skript
otvoril porty vo firewalle. Potom spusti:

```powershell
cd $HOME\Documents\distribuovane_technologie
powershell -ExecutionPolicy Bypass -File .\scripts\deploy-node.ps1 -EnvFile config\hosts\node-c.env -OpenFirewall
```

Prvé spustenie trvá niekoľko minút (sťahuje sa MySQL, PHP a nginx). Na konci uvidíš:

```
Uzol C beží: http://localhost:8080
Dostupnosť peerov:
  A  http://<IP Filipa>:9080  online
  B  http://<IP Filipa>:9180  online
```

### 6. Vyskúšaj to

1. Otvor **http://localhost:8080**. Hore v časti *Stav uzlov* by mali byť tri zelené karty A, B, C.
2. Do pár sekúnd sa ti stiahnu všetky záznamy, ktoré už existujú na A a B.
3. Vytvor poruchu (formulár vľavo). Filip ju do 2–3 sekúnd uvidí u seba na A aj na B.
4. Upravovať a mazať môžeš iba záznamy, ktoré vznikli na tvojom uzle (vlastník `C`).

## Bežné príkazy

Spúšťaj ich v priečinku projektu:

| Čo | Príkaz |
|---|---|
| Zastaviť uzol | `docker compose -f docker-compose.node.yml --env-file config\hosts\node-c.env stop` |
| Znova spustiť | `docker compose -f docker-compose.node.yml --env-file config\hosts\node-c.env start` |
| Logy synchronizácie | `docker compose -f docker-compose.node.yml --env-file config\hosts\node-c.env logs -f worker` |
| Úplné odstránenie aj s dátami | `docker compose -f docker-compose.node.yml --env-file config\hosts\node-c.env down -v` |

Dáta sú uložené v Docker volume, takže prežijú zastavenie aj reštart počítača.
Po reštarte stačí spustiť Docker Desktop a uzol sa spustí sám.

## Keď niečo nejde

* **`TcpTestSucceeded : False` alebo peery sú `NEDOSTUPNÝ`**
  * Ste v rovnakej sieti? Školské a firemné Wi-Fi siete často blokujú spojenia medzi zariadeniami
    (izolácia klientov). Najspoľahlivejšie je pripojiť oba počítače na **hotspot z mobilu**.
  * Beží Filipov PC a VM? Filip to overí cez `http://localhost:8080`.
  * Firewall na Filipovom PC: porty otvára jeho setup skript, ktorý zobrazí UAC okno.
* **Zmenila sa IP adresa** (iná sieť, nové pripojenie): pošli Filipovi novú IP. Filip spustí
  setup znova a pošle ti nový `node-c.env`. Prepíš ním starý a zopakuj krok 5. Dáta ostanú zachované.
* **Docker hlási chybu pri spustení:** skontroluj, že Docker Desktop beží (`docker ps` nesmie hlásiť chybu).
* **Port 8080 alebo 9080 je obsadený** inou aplikáciou: povedz Filipovi, vygeneruje konfiguráciu s inými portami.

## Linux / macOS

Postup je rovnaký, iba krok 5 vyzerá takto:

```bash
sh scripts/deploy-node.sh config/hosts/node-c.env
```

Na Linuxe s firewallom `ufw` ešte povoľ porty: `sudo ufw allow 8080,9080/tcp`.
