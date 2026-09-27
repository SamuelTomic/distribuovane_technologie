# distribuovane_technologie


https://share.gemini.google/CuDLo9pfY5Tv


Variant 2: Kontajnerizovaný distribuovaný IS
Každý uzol bude obsahovať minimálne:
•	kontajner webovej aplikácie alebo REST API, 
•	databázový kontajner, 
•	voliteľne samostatný synchronizačný worker, 
•	vlastný persistentný volume. 
Nasadenie bude definované pomocou Docker Compose alebo obdobného nástroja. Všetky uzly používajú rovnaký obraz aplikácie, ale odlišnú konfiguráciu NODE_ID.
Minimálne požiadavky:
•	spustenie troch uzlov z konfiguračných súborov, 
•	vlastná databáza pre každý uzol, 
•	automatická alebo manuálna online replikácia, 
•	zachovanie údajov po reštarte kontajnera, 
•	jednoduchý stavový panel uzlov. 
Rozšírené riešenie:
•	odpojenie jedného uzla od siete, 
•	lokálne pokračovanie práce, 
•	trvalé uloženie neodoslaných operácií, 
•	automatická synchronizácia po pripojení, 
•	idempotentné opakovanie operácií, 
•	health checks, centralizované logovanie a automatické nasadenie. 
Tri kontajnery na jednom počítači sú vhodné na základnú simuláciu. Pre plné hodnotenie by som požadoval tri virtuálne stroje alebo viac Docker hostiteľov. Docker overlay sieť je určená práve na komunikáciu kontajnerov medzi viacerými Docker hostiteľmi a využíva Swarm režim. Docker – overlay networks
