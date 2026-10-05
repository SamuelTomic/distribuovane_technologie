#!/bin/sh
# Simulácia výpadku uzla na Linux hostiteľovi (spúšťať ako root na hostiteľovi uzla, napr. VM s uzlom B).
# Zablokuje iba replikačnú komunikáciu – UI na UI_PORT ostáva dostupné, uzol pracuje lokálne.
#   sudo sh scripts/partition.sh on  config/hosts/node-b.env
#   sudo sh scripts/partition.sh off config/hosts/node-b.env
set -eu
ACTION=${1:?Použitie: partition.sh on|off config/hosts/node-X.env}
ENV_FILE=${2:?Chýba konfiguračný súbor uzla}
env_value() { grep "^$1=" "$ENV_FILE" | cut -d= -f2- | tr -d '\r'; }
PEER_PORT=$(env_value PEER_PORT)
PEER_PORT=${PEER_PORT:-9080}
CHAIN=DT-PARTITION

if [ "$ACTION" = on ]; then
    iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
    # prichádzajúca replikácia od peerov (Docker robí DNAT, preto porovnávame pôvodný cieľový port)
    iptables -A "$CHAIN" -p tcp -m conntrack --ctorigdstport "$PEER_PORT" --ctdir ORIGINAL -j DROP
    # odchádzajúca replikácia z kontajnerov uzla na každý peer (host:port z PEER_NODES)
    for url in $(env_value PEER_NODES | tr ',' '\n' | cut -d= -f2-); do
        hostport=${url#*://}
        hostport=${hostport%%/*}
        iptables -A "$CHAIN" -p tcp -d "${hostport%:*}" --dport "${hostport##*:}" -j DROP
    done
    iptables -C DOCKER-USER -j "$CHAIN" 2>/dev/null || iptables -I DOCKER-USER -j "$CHAIN"
    # zrušenie už otvorených spojení, aby blokovanie platilo okamžite
    if command -v conntrack >/dev/null; then
        conntrack -D -p tcp --orig-port-dst "$PEER_PORT" >/dev/null 2>&1 || true
    fi
    echo "Uzol odpojený od replikácie:"
    iptables -S "$CHAIN" | sed 's/^/  /'
else
    iptables -D DOCKER-USER -j "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    iptables -X "$CHAIN" 2>/dev/null || true
    echo "Replikácia znova povolená."
fi
