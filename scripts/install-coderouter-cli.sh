#!/usr/bin/env bash
# Install the pinned CodeRouter CLI into an app bundle.
#
# The release publishes one signed Mach-O binary per macOS architecture. The
# cmux app is universal, so this script verifies both slices and combines them
# when Xcode builds both architectures.
#
# Usage:
#   scripts/install-coderouter-cli.sh <app-Resources/bin-directory>
#
# Environment overrides are for local development and CI mirrors:
#   CMUX_CODEROUTER_CLI_LOCAL       use a local universal or thin binary
#   CMUX_CODEROUTER_CLI_CACHE       cache directory for downloaded slices
#   CMUX_CODEROUTER_DOWNLOAD_BASE_URL  release asset base URL
#   CMUX_CODEROUTER_VERSION         release version (must match pinned checksums)
set -euo pipefail

DEST_DIR="${1:?usage: $0 <app-Resources/bin-directory>}"
DEST="$DEST_DIR/coderouter"
REAL_DEST="$DEST_DIR/coderouter-bin"
VERSION="${CMUX_CODEROUTER_VERSION:-0.3.5}"
BASE_URL="${CMUX_CODEROUTER_DOWNLOAD_BASE_URL:-https://github.com/manaflow-ai/coderouter-releases/releases/download/v${VERSION}}"
CACHE_DIR="${CMUX_CODEROUTER_CLI_CACHE:-${HOME}/Library/Caches/cmux/coderouter-cli/${VERSION}}"

[[ "$VERSION" == "0.3.5" ]] || {
  echo "error: unsupported CodeRouter version $VERSION (checksums are pinned for 0.3.5)" >&2
  exit 1
}

# These checksums are from coderouter-releases v0.3.5. Keep them in source so
# a changed or compromised release asset cannot enter a shipped app.
ARM64_SHA256="755339ca0d3d762e1e4a9223bc52438b844dd55097fab8164ef300c1cad9d1c4"
X86_64_SHA256="897b184f8b8291182e3079462327a9469072f5cc72b5706a8ef5ae156be8393b"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

requested_archs=" ${ARCHS:-$(uname -m)} "
need_arm64=0
need_x86_64=0
case "$requested_archs" in
  *" arm64 "*) need_arm64=1 ;;
esac
case "$requested_archs" in
  *" x86_64 "*) need_x86_64=1 ;;
esac
if [[ "$need_arm64" -eq 0 && "$need_x86_64" -eq 0 ]]; then
  case "$(uname -m)" in
    arm64|aarch64) need_arm64=1 ;;
    x86_64|amd64) need_x86_64=1 ;;
    *) echo "error: unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi

mkdir -p "$DEST_DIR"

install_verified() {
  local source="$1"
  local output="$REAL_DEST.tmp"
  install -m 0755 "$source" "$output"
  mv -f "$output" "$REAL_DEST"
}

install_wrapper() {
  local output="$DEST.tmp"
  cat > "$output" <<'EOF'
#!/bin/bash
# Use the cmux Stack session for CodeRouter control-plane commands when the
# app is signed in. The app writes a private, short-lived config directory;
# this wrapper removes it after the real CLI exits.
set -u

SCRIPT_DIR="${0%/*}"
if [[ "$SCRIPT_DIR" == "$0" ]]; then
  SCRIPT_DIR="$PWD"
else
  SCRIPT_DIR="$(cd -- "$SCRIPT_DIR" && pwd -P)"
fi
REAL="$SCRIPT_DIR/coderouter-bin"
CMUX="$SCRIPT_DIR/cmux"
BROKER_DIR=""

cleanup() {
  if [[ -n "$BROKER_DIR" && -d "$BROKER_DIR" ]]; then
    /bin/rm -rf -- "$BROKER_DIR"
  fi
}
trap cleanup EXIT

case "${1:-}" in
  -V|--version|version|-h|--help|help|capabilities|upgrade)
    "$REAL" "$@"
    exit $?
    ;;
  logout)
    echo 'CodeRouter uses the cmux session. Run `cmux auth logout` to sign out.' >&2
    exit 2
    ;;
  login)
    if [[ -x "$CMUX" ]]; then
      if [[ "$#" -gt 1 ]]; then
        "$CMUX" auth login "${@:2}"
      else
        "$CMUX" auth login
      fi
      exit $?
    fi
    "$REAL" "$@"
    exit $?
    ;;
esac

if [[ -z "${CODEROUTER_DATA_DIR:-}" && -x "$CMUX" ]]; then
  set +e
  candidate="$($CMUX coderouter broker-config 2>/dev/null)"
  broker_status=$?
  set -u
  tmp_root="${TMPDIR:-/tmp}"
  tmp_root="${tmp_root%/}"
  candidate_root="${candidate%/}"
  candidate_parent="${candidate_root%/*}"
  candidate_parent="${candidate_parent%/}"
  candidate_name="${candidate_root##*/}"
  if [[ "$broker_status" -eq 0 \
        && "$candidate_parent" == "$tmp_root" \
        && "$candidate_name" == cmux-coderouter-broker-* \
        && -d "$candidate_root/coderouter" \
        && -f "$candidate_root/coderouter/config.json" ]]; then
    BROKER_DIR="$candidate_root"
    export CODEROUTER_DATA_DIR="$BROKER_DIR"
  else
    echo 'CodeRouter uses the cmux session. Run `cmux auth login`, then retry.' >&2
    exit 1
  fi
fi

"$REAL" "$@"
exit $?
EOF
  chmod 0755 "$output"
  mv -f "$output" "$DEST"
}

if [[ -n "${CMUX_CODEROUTER_CLI_LOCAL:-}" ]]; then
  local_binary="$CMUX_CODEROUTER_CLI_LOCAL"
  [[ -f "$local_binary" ]] || {
    echo "error: CMUX_CODEROUTER_CLI_LOCAL does not exist: $local_binary" >&2
    exit 1
  }
  install_verified "$local_binary"
else
  command -v curl >/dev/null 2>&1 || { echo "error: curl is required to bundle CodeRouter" >&2; exit 1; }
  command -v shasum >/dev/null 2>&1 || { echo "error: shasum is required to bundle CodeRouter" >&2; exit 1; }
  command -v lipo >/dev/null 2>&1 || { echo "error: lipo is required to bundle CodeRouter" >&2; exit 1; }

  mkdir -p "$CACHE_DIR"

  fetch_slice() {
    local name="$1"
    local expected="$2"
    local output="$CACHE_DIR/$name"
    local actual
    if [[ ! -f "$output" ]] || [[ "$(sha256_of "$output")" != "$expected" ]]; then
      local temporary
      temporary="$(mktemp "$output.tmp.XXXXXX")"
      curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --retry-delay 2 \
        "$BASE_URL/$name" -o "$temporary"
      actual="$(sha256_of "$temporary")"
      if [[ "$actual" != "$expected" ]]; then
        rm -f "$temporary"
        echo "error: CodeRouter checksum mismatch for $name (want $expected, got $actual)" >&2
        exit 1
      fi
      mv -f "$temporary" "$output"
    fi
    printf '%s' "$output"
  }

  if [[ "$need_arm64" -eq 1 && "$need_x86_64" -eq 1 ]]; then
    arm64="$(fetch_slice coderouter-darwin-arm64 "$ARM64_SHA256")"
    x86_64="$(fetch_slice coderouter-darwin-x64 "$X86_64_SHA256")"
    universal="$CACHE_DIR/coderouter-universal"
    if [[ ! -f "$universal" ]] || ! lipo "$universal" -verify_arch arm64 >/dev/null 2>&1 || ! lipo "$universal" -verify_arch x86_64 >/dev/null 2>&1; then
      lipo -create "$arm64" "$x86_64" -output "$universal.tmp"
      mv -f "$universal.tmp" "$universal"
    fi
    install_verified "$universal"
  elif [[ "$need_arm64" -eq 1 ]]; then
    install_verified "$(fetch_slice coderouter-darwin-arm64 "$ARM64_SHA256")"
  else
    install_verified "$(fetch_slice coderouter-darwin-x64 "$X86_64_SHA256")"
  fi
fi

install_wrapper

for arch in arm64 x86_64; do
  case "$requested_archs" in
    *" $arch "*)
      lipo "$REAL_DEST" -verify_arch "$arch" >/dev/null
      ;;
  esac
done

[[ -x "$REAL_DEST" && -x "$DEST" ]] || { echo "error: CodeRouter CLI was not installed at $DEST_DIR" >&2; exit 1; }
echo "Installed CodeRouter CLI ${VERSION} at $DEST"
