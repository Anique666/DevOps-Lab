#!/bin/bash
set -euo pipefail

PROFILE_NAME=my-apparmor-profile
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/$PROFILE_NAME"
TARGET="/etc/apparmor.d/$PROFILE_NAME"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo: sudo ./install-profile.sh" >&2
    exit 1
fi

if [ ! -d /etc/apparmor.d ] || ! command -v apparmor_parser >/dev/null; then
    echo "AppArmor is not installed or not enabled on this host." >&2
    echo "This lab needs a host with AppArmor support (for example Ubuntu)." >&2
    exit 1
fi

install -m 0644 "$SOURCE" "$TARGET"
apparmor_parser -r "$TARGET"

echo "Loaded profile:"
cat /sys/kernel/security/apparmor/profiles | grep "$PROFILE_NAME"
