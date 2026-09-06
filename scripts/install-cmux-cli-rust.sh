#!/usr/bin/env bash
# Install the Rust CLI migration artifacts into an existing cmux app.
#
# The installer uses separate names during migration so the Swift `cmux` CLI
# and the verified upstream CodeRouter executable remain the production paths.
# After the parity manifest is complete, release packaging can rename these
# artifacts to `cmux` and `coderouter` in one explicit cutover.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH=""
ARCHS_RAW="${CMUX_CLI_RUST_ARCHS:-}"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/install-cmux-cli-rust.sh <cmux.app> [--archs "arm64 x86_64"]

Installs:
  Contents/Resources/bin/cmux-rust
  Contents/Resources/bin/coderouter-rust

The names stay separate until the parity manifest allows cutover.
USAGE
}

while (($#)); do
  case "$1" in
    --archs)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ARCHS_RAW="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option $1" >&2
      usage
      exit 2
      ;;
    *)
      [[ -z "$APP_PATH" ]] || { echo "error: more than one app path" >&2; exit 2; }
      APP_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$APP_PATH" && -d "$APP_PATH/Contents" ]] || {
  echo "error: cmux app bundle not found at '${APP_PATH:-<missing>}'" >&2
  exit 1
}

OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cli-rust.XXXXXX")"
cleanup() { rm -rf "$OUTPUT_DIR"; }
trap cleanup EXIT

build_args=(--output-dir "$OUTPUT_DIR")
if [[ -n "$ARCHS_RAW" ]]; then
  build_args+=(--archs "$ARCHS_RAW")
fi
CMUX_ALLOW_LOW_SPACE_BUILD="${CMUX_ALLOW_LOW_SPACE_BUILD:-1}" \
  "$ROOT/scripts/build-cmux-cli-rust.sh" "${build_args[@]}"

DEST_DIR="$APP_PATH/Contents/Resources/bin"
mkdir -p "$DEST_DIR"
install -m 0755 "$OUTPUT_DIR/cmux" "$DEST_DIR/cmux-rust"
install -m 0755 "$OUTPUT_DIR/coderouter" "$DEST_DIR/coderouter-rust"
echo "Installed Rust CLI migration artifacts in $DEST_DIR"
