#!/bin/sh
# Nasadenie do Docker Swarm (spúšťať na manager uzle).
#   1) manager:  docker swarm init --advertise-addr <IP>
#      ostatné:  docker swarm join --token ... <IP>:2377
#   2) manager:  docker node update --label-add dt_node=a <hostname-A>   (b, c obdobne)
#   3) každý hostiteľ: docker build -t dt-node:1.0.0 --build-arg APP_VERSION=1.0.0 .
#   4) manager:  sh scripts/deploy-swarm.sh
set -eu
cd "$(dirname "$0")/.."
[ -f config/swarm/secrets.env ] || { echo "Chýba config/swarm/secrets.env (vzor: secrets.env.example)" >&2; exit 1; }
set -a; . ./config/swarm/secrets.env; set +a
docker stack deploy --detach=false -c docker-stack.yml dt
docker stack services dt
