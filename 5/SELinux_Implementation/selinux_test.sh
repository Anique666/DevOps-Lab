#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-flask-apparmor}"
APP_PORT="${APP_PORT:-15005}"
APP_NAME=""
TEST_DIR=""
failures=0

cleanup() {
    if [ -n "$APP_NAME" ]; then
        docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
    fi
    if [ -n "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

if ! command -v getenforce >/dev/null 2>&1; then
    echo "getenforce not found. This script needs a SELinux host (for example Fedora)." >&2
    exit 1
fi

if [ "$(getenforce)" != "Enforcing" ]; then
    echo "SELinux must be enforcing. Run $SCRIPT_DIR/selinux_setup.sh first." >&2
    exit 1
fi

if ! docker info --format '{{json .SecurityOptions}}' | grep -q 'selinux'; then
    echo "Docker does not report SELinux support." >&2
    exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -t "$IMAGE" "$LAB_DIR"
fi

echo "=== 1. SELinux type enforcement on a bind-mounted host file ==="
TEST_DIR="$(mktemp -d "$HOME/selinux-lab-test.XXXXXX")"
printf 'host home data\n' > "$TEST_DIR/data.txt"
chmod 0644 "$TEST_DIR/data.txt"
echo "Host label before Docker relabeling:"
ls -ldZ "$TEST_DIR"
ls -lZ "$TEST_DIR/data.txt"

set +e
OUTPUT="$(docker run --rm -v "$TEST_DIR:/data:ro" "$IMAGE" \
    cat /data/data.txt 2>&1)"
RC=$?
set -e
echo "Without a matching label (no :z), exit=$RC:"
echo "$OUTPUT"
if [ "$RC" -eq 0 ]; then
    echo "UNEXPECTED: the container read a user_home_t file without relabeling."
    failures=$((failures + 1))
else
    echo "PASS: SELinux denied the read of the user_home_t file."
fi

echo
echo "With Docker's :z relabel option:"
set +e
OUTPUT="$(docker run --rm -v "$TEST_DIR:/data:ro,z" "$IMAGE" \
    cat /data/data.txt 2>&1)"
RC=$?
set -e
echo "$OUTPUT"
echo "Host label after Docker relabeling:"
LABEL_LINE="$(ls -lZ "$TEST_DIR/data.txt")"
echo "$LABEL_LINE"
if [ "$RC" -eq 0 ] && [ "$OUTPUT" = "host home data" ] && \
    printf '%s' "$LABEL_LINE" | grep -q 'container_file_t'; then
    echo "PASS: Docker relabeled the test file to container_file_t and access succeeded."
else
    echo "UNEXPECTED: the :z relabel did not produce the expected label or output."
    failures=$((failures + 1))
fi

echo
echo "=== 2. Capability restriction with --cap-drop=ALL ==="
CAP_TEST='import os; open("/tmp/probe", "w").close(); os.chown("/tmp/probe", 1000, 1000); print("chown succeeded")'
echo "Default Docker capability set:"
docker run --rm "$IMAGE" grep CapEff /proc/self/status
set +e
OUTPUT="$(docker run --rm "$IMAGE" python -c "$CAP_TEST" 2>&1)"
RC=$?
set -e
echo "Default container chown, exit=$RC:"
echo "$OUTPUT"
if [ "$RC" -ne 0 ]; then
    echo "UNEXPECTED: chown failed even with Docker's default capabilities."
    failures=$((failures + 1))
else
    echo "PASS: chown worked with Docker's default capabilities (CAP_CHOWN present)."
fi

echo
echo "Dropped capability set:"
docker run --rm --cap-drop=ALL "$IMAGE" grep CapEff /proc/self/status
set +e
OUTPUT="$(docker run --rm --cap-drop=ALL "$IMAGE" python -c "$CAP_TEST" 2>&1)"
RC=$?
set -e
echo "cap-drop=ALL container chown, exit=$RC:"
echo "$OUTPUT"
if [ "$RC" -eq 0 ]; then
    echo "UNEXPECTED: chown succeeded after dropping all capabilities."
    failures=$((failures + 1))
else
    echo "PASS: dropping all capabilities denied chown."
fi

echo
echo "=== 3. no-new-privileges flag ==="
NONEWPRIVS="$(docker run --rm --security-opt no-new-privileges "$IMAGE" \
    grep NoNewPrivs /proc/self/status)"
echo "$NONEWPRIVS"
if printf '%s' "$NONEWPRIVS" | grep -qE 'NoNewPrivs:[[:space:]]*1'; then
    echo "PASS: the no-new-privileges flag was active in the container."
else
    echo "UNEXPECTED: NoNewPrivs was not 1."
    failures=$((failures + 1))
fi

echo
echo "=== 4. Hardened Flask container with SELinux labels ==="
APP_NAME="flask-selinux-check-$$"
docker run -d --name "$APP_NAME" \
    --security-opt label=type:container_t \
    --security-opt label=level:s0:c100,c200 \
    --security-opt no-new-privileges \
    --cap-drop=ALL \
    --read-only \
    --tmpfs /tmp \
    -p "127.0.0.1:${APP_PORT}:5000" \
    "$IMAGE" >/dev/null

BODY=""
for _ in $(seq 1 30); do
    if BODY="$(curl -fsS "http://127.0.0.1:${APP_PORT}/" 2>/dev/null)"; then
        break
    fi
    sleep 1
done

CONFIG="$(docker inspect "$APP_NAME" --format \
    'SecurityOpt={{json .HostConfig.SecurityOpt}} ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} CapDrop={{json .HostConfig.CapDrop}} ProcessLabel={{.ProcessLabel}} MountLabel={{.MountLabel}}')"
echo "Docker configuration:"
echo "$CONFIG"
if printf '%s' "$CONFIG" | grep -Fq 'label=type:container_t' && \
    printf '%s' "$CONFIG" | grep -Fq 'label=level:s0:c100,c200' && \
    printf '%s' "$CONFIG" | grep -Fq 'no-new-privileges' && \
    printf '%s' "$CONFIG" | grep -Fq 'ReadonlyRootfs=true' && \
    printf '%s' "$CONFIG" | grep -Fq 'CapDrop=["ALL"]'; then
    echo "PASS: Docker applied the requested labels and hardening options."
else
    echo "UNEXPECTED: one or more requested Docker options are missing."
    failures=$((failures + 1))
fi

APP_LABEL="$(docker exec "$APP_NAME" sh -c 'cat /proc/self/attr/current | tr -d "\000"; echo')"
echo "Effective container label:"
echo "$APP_LABEL"
if [ "$APP_LABEL" = "system_u:system_r:container_t:s0:c100,c200" ]; then
    echo "PASS: the container runs under the explicit SELinux type and MCS level."
else
    echo "UNEXPECTED: the effective label is not the requested SELinux label."
    failures=$((failures + 1))
fi

APP_STATUS="$(docker exec "$APP_NAME" grep -E 'CapEff|NoNewPrivs' /proc/self/status)"
echo "Effective capabilities and no-new-privileges:"
echo "$APP_STATUS"
if printf '%s' "$APP_STATUS" | grep -qE 'CapEff:[[:space:]]*0000000000000000' && \
    printf '%s' "$APP_STATUS" | grep -qE 'NoNewPrivs:[[:space:]]*1'; then
    echo "PASS: the hardened app has no effective capabilities and NoNewPrivs=1."
else
    echo "UNEXPECTED: capabilities or NoNewPrivs do not match the requested state."
    failures=$((failures + 1))
fi

echo "HTTP response:"
echo "$BODY"
if printf '%s' "$BODY" | grep -q 'secure Flask application'; then
    echo "PASS: the Flask application still responds under the hardened configuration."
else
    echo "FAIL: the Flask application did not return the expected response."
    failures=$((failures + 1))
fi

set +e
OUTPUT="$(docker exec "$APP_NAME" python -c "$CAP_TEST" 2>&1)"
RC=$?
set -e
echo "chown inside the hardened app, exit=$RC:"
echo "$OUTPUT"
if [ "$RC" -eq 0 ]; then
    echo "UNEXPECTED: chown succeeded with --cap-drop=ALL."
    failures=$((failures + 1))
else
    echo "PASS: chown was denied inside the hardened app."
fi

set +e
OUTPUT="$(docker exec "$APP_NAME" sh -c 'echo probe >/etc/probe' 2>&1)"
RC=$?
set -e
echo "Write to /etc inside the read-only app, exit=$RC:"
echo "$OUTPUT"
if [ "$RC" -eq 0 ]; then
    echo "UNEXPECTED: the read-only root filesystem allowed a write to /etc."
    failures=$((failures + 1))
else
    echo "PASS: the read-only root filesystem denied the write."
fi

echo
echo "=== 5. AppArmor path-based and exec rules are not reproduced ==="
docker exec "$APP_NAME" sh -c 'head -1 /etc/passwd'
echo "OBSERVED: the container can still read its own /etc/passwd. SELinux"
echo "container_t does not apply the AppArmor profile's path-based deny rule."
echo
docker exec "$APP_NAME" /bin/sh -c 'echo shell executed'
echo "OBSERVED: /bin/sh still executes. Default container_t policy does not"
echo "block binaries inside the image; no custom SELinux exec policy was added."

echo
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures check(s) did not behave as expected."
    exit 1
fi
echo "RESULT: all SELinux and container-hardening checks passed."
