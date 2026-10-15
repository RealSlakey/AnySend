#!/usr/bin/env bash
# Cross-compile the Go tsnet bridge to a .so for HarmonyOS NEXT (arm64).
#
# Prerequisites:
#   - Go 1.22+
#   - OpenHarmony NDK (set OHOS_NDK_HOME) with the llvm toolchain
#
# The OpenHarmony NDK provides aarch64-unknown-linux-ohos-clang which
# targets the HarmonyOS libc. We set GOOS=linux (OpenHarmony uses a Linux
# kernel) and use the ohos clang as the C compiler so cgo links against
# the correct libc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_DIR="${SCRIPT_DIR}/../go"
OUT_DIR="${GO_DIR}/cmd/cshared/out"
mkdir -p "${OUT_DIR}"

if [ -z "${OHOS_NDK_HOME:-}" ]; then
  echo "ERROR: OHOS_NDK_HOME is not set. Point it at your OpenHarmony NDK." >&2
  exit 1
fi

OHOS_LLVM="${OHOS_NDK_HOME}/llvm"
CC="${OHOS_LLVM}/bin/aarch64-unknown-linux-ohos-clang"

if [ ! -x "${CC}" ]; then
  echo "ERROR: clang not found at ${CC}" >&2
  exit 1
fi

echo "Cross-compiling libtsnetbridge.so for arm64-ohos..."
cd "${GO_DIR}"
CGO_ENABLED=1 \
GOOS=linux \
GOARCH=arm64 \
CC="${CC}" \
CXX="${OHOS_LLVM}/bin/aarch64-unknown-linux-ohos-clang++" \
  go build -buildmode=c-shared -o "${OUT_DIR}/libtsnetbridge.so" ./cmd/cshared

echo "Output: ${OUT_DIR}/libtsnetbridge.so"
file "${OUT_DIR}/libtsnetbridge.so"
