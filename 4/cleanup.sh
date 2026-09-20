#!/bin/bash
set -euo pipefail

NETWORK=my-bridge-net
LABEL=4-docker-networking

# Only remove containers that carry this lab's label.
for container in mysql redis flask; do
    label=$(docker inspect -f '{{ index .Config.Labels "lab" }}' "$container" 2>/dev/null || true)
    if [ "$label" = "$LABEL" ]; then
        docker stop "$container" >/dev/null 2>&1 || true
        docker rm "$container" >/dev/null 2>&1 || true
        echo "Removed $container"
    fi
done

net_label=$(docker network inspect -f '{{ index .Labels "lab" }}' "$NETWORK" 2>/dev/null || true)
if [ "$net_label" = "$LABEL" ]; then
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    echo "Removed network $NETWORK"
fi
