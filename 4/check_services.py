"""Check that the MySQL and Redis ports are reachable by container name."""

import socket

SERVICES = {"mysql": 3306, "redis": 6379}

for name, port in SERVICES.items():
    try:
        with socket.create_connection((name, port), timeout=3):
            print(f"{name}:{port} reachable")
    except OSError as exc:
        print(f"{name}:{port} not reachable: {exc}")
