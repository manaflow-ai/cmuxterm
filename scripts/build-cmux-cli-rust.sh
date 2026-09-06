#!/usr/bin/env bash
# Build the Rust cmux and standalone CodeRouter CLI entry points.
#
# This script is intentionally separate from the full cmux-tui client build.
# The local CLI must not inherit TUI, PTY, browser, or remote transport
# dependencies just because both products use Rust.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/cmux-tui/Cargo.toml"
OUTPUT_DIR=""
ARCHS_RAW="${CMUX_CLI_RUST_ARCHS:-}"
PROFILE="release"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/build-cmux-cli-rust.sh --output-dir <directory> [options]

Options:
  --output-dir <directory>  directory for cmux and coderouter binaries
  --archs "arm64 x86_64"    macOS architectures (default: host architecture)
  --profile <debug|release> Cargo profile (default: release)

The output directory contains two separate executables:
  cmux        the cmux CLI compatibility entry point
  coderouter  the standalone CodeRouter entry point
USAGE
}

while (($#)); do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --archs)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ARCHS_RAW="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[[ -n "$OUTPUT_DIR" ]] || { echo "error: --output-dir is required" >&2; usage; exit 2; }
[[ "$PROFILE" == "debug" || "$PROFILE" == "release" ]] || {
  echo "error: profile must be debug or release" >&2
  exit 2
}
command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required for the Swift dispatch inventory check" >&2; exit 1; }
python3 "$ROOT/scripts/generate-cli-rust-command-inventory.py" --check

if [[ -z "$ARCHS_RAW" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCHS_RAW="arm64" ;;
    x86_64|amd64) ARCHS_RAW="x86_64" ;;
    *) echo "error: unsupported host architecture $(uname -m)" >&2; exit 1 ;;
  esac
fi

rust_target_for_arch() {
  case "$1" in
    arm64|arm64e) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) echo "error: unsupported Rust macOS architecture $1" >&2; return 1 ;;
  esac
}

ensure_target() {
  local target="$1"
  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$target"; then
    echo "Installing Rust target $target" >&2
    rustup target add "$target"
  elif ! command -v rustup >/dev/null 2>&1 && ! rustc -vV | grep -q "host: .*${target}"; then
    echo "error: Rust target $target is not installed; install rustup or run: rustup target add $target" >&2
    return 1
  fi
}

mkdir -p "$OUTPUT_DIR"
build_dir="$ROOT/cmux-tui/target/cmux-cli-rust/$PROFILE"
rm -rf "$build_dir"
mkdir -p "$build_dir"
declare -a CMUX_SLICES=()
declare -a CODEROUTER_SLICES=()
declare -a SEEN_TARGETS=()

for arch in $ARCHS_RAW; do
  target="$(rust_target_for_arch "$arch")"
  case " ${SEEN_TARGETS[*]} " in *" $target "*) continue ;; esac
  SEEN_TARGETS+=("$target")
  ensure_target "$target"
  cargo build --manifest-path "$MANIFEST" -p cmux-cli --profile "$PROFILE" --target "$target" --locked
  CMUX_SLICES+=("$ROOT/cmux-tui/target/$target/$PROFILE/cmux")
  CODEROUTER_SLICES+=("$ROOT/cmux-tui/target/$target/$PROFILE/coderouter")
done

install_binary() {
  local destination="$1"
  shift
  if [[ "${#}" -eq 1 ]]; then
    install -m 0755 "$1" "$destination"
  else
    command -v lipo >/dev/null 2>&1 || { echo "error: lipo is required for universal output" >&2; exit 1; }
    lipo -create "$@" -output "$destination.tmp"
    chmod 0755 "$destination.tmp"
    mv -f "$destination.tmp" "$destination"
  fi
}

install_binary "$OUTPUT_DIR/cmux" "${CMUX_SLICES[@]}"
install_binary "$OUTPUT_DIR/coderouter" "${CODEROUTER_SLICES[@]}"

for binary in "$OUTPUT_DIR/cmux" "$OUTPUT_DIR/coderouter"; do
  [[ -x "$binary" ]] || { echo "error: missing output $binary" >&2; exit 1; }
done
echo "Built Rust CLI binaries in $OUTPUT_DIR"
