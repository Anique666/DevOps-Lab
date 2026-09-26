#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-flask-apparmor}"

if ! command -v getenforce >/dev/null 2>&1; then
    echo "getenforce not found. This script needs a SELinux host (for example Fedora)." >&2
    exit 1
fi

MODE="$(getenforce)"
echo "SELinux mode: $MODE"
if [ "$MODE" != "Enforcing" ]; then
    echo "SELinux is not enforcing. Set it to enforcing before running this lab." >&2
    exit 1
fi

echo
echo "=== SELinux status ==="
sestatus
grep -E '^SELINUX=' /etc/selinux/config || true

echo
echo "=== Docker SELinux support ==="
docker info --format '{{json .SecurityOptions}}'
if ! docker info --format '{{json .SecurityOptions}}' | grep -q 'selinux'; then
    echo "Docker does not report SELinux support." >&2
    exit 1
fi

echo
echo "=== Build the lab image if needed ==="
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image already present: $IMAGE"
else
    docker build -t "$IMAGE" "$LAB_DIR"
fi

echo
echo "=== Effective label of a default container ==="
docker run --rm "$IMAGE" sh -c 'cat /proc/self/attr/current | tr -d "\000"; echo'

echo
echo "=== Configured labels for an explicit SELinux type and MCS level ==="
CID="$(docker create \
    --security-opt label=type:container_t \
    --security-opt label=level:s0:c100,c200 \
    "$IMAGE" true)"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
docker inspect "$CID" --format \
    'SecurityOpt={{json .HostConfig.SecurityOpt}} ProcessLabel={{.ProcessLabel}} MountLabel={{.MountLabel}}'
docker rm -f "$CID" >/dev/null
trap - EXIT

echo
echo "These are SELinux labels, not an AppArmor profile."
echo "Continue with $SCRIPT_DIR/selinux_test.sh to test label-based access and capabilities."
