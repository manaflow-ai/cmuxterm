#!/usr/bin/env bash
# Compile the real batch sources/tests and CLI adapter without Xcode or SwiftPM.
# This harness does not verify the full CLI's routing or production SocketClient.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cmux-rpc-batch.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
DEVELOPER="$(xcode-select -p)"
TOOLCHAIN="$(dirname "$(xcrun --find swiftc)")/.."
FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
if [[ ! -d "$FRAMEWORKS/Testing.framework" ]]; then
  FRAMEWORKS="$DEVELOPER/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi
CORE="$ROOT/Packages/macOS/CmuxFoundation"
xcrun swiftc -swift-version 6 -enable-upcoming-feature ExistentialAny \
  -enable-upcoming-feature InternalImportsByDefault -enable-testing \
  -emit-library -emit-module -module-name CmuxFoundation \
  "$CORE"/Sources/CmuxFoundation/RPCBatch/*.swift \
  "$CORE/Sources/CmuxFoundation/CmuxCLIArgumentParser.swift" \
  -emit-module-path "$BUILD/CmuxFoundation.swiftmodule" -o "$BUILD/libCmuxFoundation.dylib"
xcrun swiftc -swift-version 6 -parse-as-library \
  -plugin-path "$TOOLCHAIN/lib/swift/host/plugins/testing" \
  -I "$BUILD" -L "$BUILD" -lCmuxFoundation -F "$FRAMEWORKS" -framework Testing \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$DEVELOPER/Library/Developer/usr/lib" \
  -Xlinker -rpath -Xlinker "$BUILD" \
  "$CORE/Tests/CmuxFoundationTests/CmuxRPCBatchTests.swift" \
  "$ROOT/tests/fixtures/rpc_batch/TestMain.swift" -o "$BUILD/batch-tests"
"$BUILD/batch-tests"
xcrun swiftc -O -swift-version 6 -parse-as-library -I "$BUILD" -L "$BUILD" \
  -lCmuxFoundation -Xlinker -rpath -Xlinker "$BUILD" \
  "$ROOT/CLI/CMUXCLI+RPCBatch.swift" "$ROOT/tests/fixtures/rpc_batch/CLIHost.swift" \
  -o "$BUILD/batch-host"
CMUX_CLI_BIN="$BUILD/batch-host" python3 "$ROOT/tests/test_cli_rpc_batch.py"
if [[ "${1:-}" == "--benchmark" ]]; then
  python3 "$ROOT/scripts/benchmark-rpc-batch.py" --cli "$BUILD/batch-host" \
    --label focused-adapter-harness
fi
