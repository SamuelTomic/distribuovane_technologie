#!/bin/sh
# Automatické nasadenie jedného uzla na Linux hostiteľovi (VM).
# Použitie (z priečinka projektu): sh scripts/deploy-node.sh config/hosts/node-b.env
set -eu
ENV_FILE=${1:?Použitie: sh scripts/deploy-node.sh config/hosts/node-X.env}
cd "$(dirname "$0")/.."
[ -f "$ENV_FILE" ] || { echo "Súbor $ENV_FILE neexistuje." >&2; exit 1; }

env_value() { grep "^$1=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r'; }

if ! docker compose -f docker-compose.node.yml --env-file "$ENV_FILE" up -d --build --wait --wait-timeout 600 --remove-orphans; then
    # Napr. zmenená konfigurácia siete – kontajnery a sieť vytvoríme nanovo (volume s dátami ostáva).
    echo "Prvý pokus zlyhal, vytváram kontajnery a sieť nanovo (dáta ostávajú)..."
    docker compose -f docker-compose.node.yml --env-file "$ENV_FILE" down --remove-orphans
    docker compose -f docker-compose.node.yml --env-file "$ENV_FILE" up -d --build --wait --wait-timeout 600
fi
docker compose -f docker-compose.node.yml --env-file "$ENV_FILE" ps

UI_PORT=$(env_value UI_PORT)
echo
echo "Uzol $(env_value NODE_ID) beží na porte ${UI_PORT:-8080}, IP adresy hostiteľa: $(hostname -I 2>/dev/null)"
echo "Dostupnosť peerov:"
env_value PEER_NODES | tr ',' '\n' | while IFS='=' read -r node url; do
    if curl -fsS -m 3 "$url/api/status" >/dev/null 2>&1; then echo "  $node  $url  online"; else echo "  $node  $url  NEDOSTUPNÝ (zatiaľ)"; fi
done
