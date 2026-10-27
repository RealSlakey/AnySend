#!/usr/bin/env bash
# Build the tsnetbridge AAR for Android using gomobile bind.
#
# Prerequisites:
#   - Go 1.22+
#   - Android NDK (set ANDROID_NDK_HOME or ANDROID_HOME)
#   - gomobile: go install golang.org/x/mobile/cmd/gomobile@latest
#   - gomobile init
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_DIR="${SCRIPT_DIR}/../go"
OUT_DIR="${SCRIPT_DIR}/../android/app/libs"
mkdir -p "${OUT_DIR}"

# Use ANDROID_NDK_HOME if set, else try ANDROID_HOME/ndk-bundle
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  if [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}/ndk-bundle" ]; then
    export ANDROID_NDK_HOME="${ANDROID_HOME}/ndk-bundle"
  fi
fi

echo "Building tsnetbridge AAR (arm64-v8a)..."
cd "${GO_DIR}"
# -s -w strips the symbol table and DWARF: tsnet drags in gVisor + the whole
# tailscale dependency tree, and unstripped libgojni.so was 41 MB of the 51 MB
# APK. -trimpath keeps machine paths out of the binary.
gomobile bind -target=android/arm64 -androidapi=24 \
  -ldflags='-s -w' -trimpath \
  -o "${OUT_DIR}/tsnetbridge.aar" \
  ./tsnetbridge

echo "AAR written to ${OUT_DIR}/tsnetbridge.aar"
