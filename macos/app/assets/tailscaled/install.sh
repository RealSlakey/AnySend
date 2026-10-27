#!/bin/sh
# Installs the AnySend Tailscale daemon (open source tailscaled) as a root
# LaunchDaemon so that this Mac joins the tailnet with a real utun interface.
#
# Must run as root. Called from the app through an administrator prompt, so it
# never assumes a password is available on stdin.
#
# Usage: install.sh <src-dir> [operator-user]
#   <src-dir>       directory containing the tailscaled / tailscale binaries
#   [operator-user] login name allowed to control the daemon without sudo

set -eu

SRC="${1:?source directory required}"
OWNER="${2:-}"

DIR="/Library/Application Support/AnySend"
LABEL="com.slakey.anysend.tailscaled"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

if [ "$(id -u)" -ne 0 ]; then
  echo "install must run as root" >&2
  exit 1
fi

if [ ! -f "${SRC}/tailscaled" ] || [ ! -f "${SRC}/tailscale" ]; then
  echo "tailscaled/tailscale binaries not found in ${SRC}" >&2
  exit 1
fi

mkdir -p "${DIR}/state"

# Assets extracted from a downloaded app keep the quarantine flag; launchd
# refuses to execute quarantined binaries.
xattr -dr com.apple.quarantine "${SRC}" 2>/dev/null || true

install -m 0755 "${SRC}/tailscaled" "${DIR}/tailscaled"
install -m 0755 "${SRC}/tailscale" "${DIR}/tailscale"

cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${DIR}/tailscaled</string>
		<string>--state=${DIR}/state/tailscaled.state</string>
		<string>--socket=${DIR}/tailscaled.sock</string>
		<string>--port=41641</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${DIR}/tailscaled.log</string>
	<key>StandardErrorPath</key>
	<string>${DIR}/tailscaled.log</string>
</dict>
</plist>
EOF

chown root:wheel "${PLIST}"
chmod 0644 "${PLIST}"

launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "${PLIST}"
launchctl enable "system/${LABEL}"

# Wait for the LocalAPI socket so the operator can be set right away.
i=0
while [ ! -S "${DIR}/tailscaled.sock" ] && [ "${i}" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done

if [ -n "${OWNER}" ] && [ -S "${DIR}/tailscaled.sock" ]; then
  # Without this the GUI can only read status; every mutating call is denied.
  "${DIR}/tailscale" --socket="${DIR}/tailscaled.sock" set --operator="${OWNER}" || true
fi

echo "installed"
