#!/bin/sh
# Removes the AnySend Tailscale daemon and all of its state.
# Must run as root.

set -eu

DIR="/Library/Application Support/AnySend"
LABEL="com.slakey.anysend.tailscaled"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

if [ "$(id -u)" -ne 0 ]; then
  echo "uninstall must run as root" >&2
  exit 1
fi

launchctl bootout "system/${LABEL}" 2>/dev/null || true
rm -f "${PLIST}"
rm -rf "${DIR}"

echo "uninstalled"
