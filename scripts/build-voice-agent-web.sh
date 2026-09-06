#!/usr/bin/env bash
# Bundle the voice agent's hidden audio page (Pipecat JS client + SmallWebRTC
# transport) into voice-agent/static/. The Python sidecar serves that folder.
#
# Usage: scripts/build-voice-agent-web.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$ROOT/voice-agent/web"
OUT="$ROOT/voice-agent/static"

if ! command -v npm >/dev/null 2>&1; then
  echo "build-voice-agent-web: npm is required (node 18+)" >&2
  exit 1
fi

cd "$WEB"
if [ ! -d node_modules ]; then
  npm install --no-audit --no-fund
fi

mkdir -p "$OUT"
npx esbuild main.ts \
  --bundle \
  --format=iife \
  --target=safari17 \
  --minify \
  --outfile="$OUT/audio.js"
cp audio.html "$OUT/audio.html"
echo "voice-agent web bundle written to $OUT"
