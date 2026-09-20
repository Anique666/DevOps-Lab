#!/bin/bash
set -euo pipefail

NETWORK=my-bridge-net
LABEL=4-docker-networking

for container in mysql redis flask; do
    if docker container inspect "$container" >/dev/null 2>&1; then
        echo "Container '$container' already exists. Run ./cleanup.sh first." >&2
        exit 1
    fi
done

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create --driver bridge --label lab="$LABEL" "$NETWORK"
fi

docker build -t flask-api .

# MYSQL_ALLOW_EMPTY_PASSWORD is only acceptable for this local lab.
docker run -d --name mysql --net="$NETWORK" --label lab="$LABEL" \
    -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.4
docker run -d --name redis --net="$NETWORK" --label lab="$LABEL" redis:7-alpine
docker run -d --name flask --net="$NETWORK" --label lab="$LABEL" -p 5001:5001 flask-api

echo "Waiting for MySQL to accept TCP connections..."
for _ in $(seq 1 30); do
    if docker exec flask python -c "import socket; socket.create_connection(('mysql', 3306), 2)" >/dev/null 2>&1; then
        echo "MySQL is ready."
        break
    fi
    sleep 2
done

echo "Waiting for the Flask app..."
for _ in $(seq 1 20); do
    if curl -fsS http://localhost:5001/about >/dev/null 2>&1; then
        echo "Flask is ready."
        break
    fi
    sleep 1
done

docker ps --filter network="$NETWORK"
