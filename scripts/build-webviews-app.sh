#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT/webviews"
OUT_DIR="$ROOT/Resources/markdown-viewer/webviews-app"
MARKED_JS="$ROOT/Resources/markdown-viewer/marked.min.js"

write_agent_session_html() {
  out_dir="$1"
  if [ ! -f "$MARKED_JS" ]; then
    echo "error: missing markdown parser asset at $MARKED_JS" >&2
    exit 1
  fi
  {
    printf '<!doctype html>\n'
    printf '<html lang="en" data-cmux-webview-kind="agent-session" data-codex-window-type="electron" data-window-type="electron" data-codex-os="darwin">\n'
    printf '  <head>\n'
    printf '    <meta charset="UTF-8" />\n'
    printf '    <meta name="viewport" content="width=device-width, initial-scale=1.0" />\n'
    printf '    <title>cmux Agent Session</title>\n'
    printf '  </head>\n'
    printf '  <body data-cmux-webview-kind="agent-session" data-codex-window-type="electron">\n'
    printf '    <main id="root"></main>\n'
    printf '    <script>\n'
    /usr/bin/perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$MARKED_JS"
    printf '\n    </script>\n'
    printf '    <script type="module" src="./main.mjs"></script>\n'
    printf '  </body>\n'
    printf '</html>\n'
  } > "$out_dir/agent-session.html"
}

write_blueprint_html() {
  out_dir="$1"
  {
    printf '<!doctype html>\n'
    printf '<html lang="en" data-cmux-webview-kind="blueprint">\n'
    printf '  <head>\n'
    printf '    <meta charset="UTF-8" />\n'
    printf '    <meta name="viewport" content="width=device-width, initial-scale=1.0" />\n'
    printf '    <title>cmux Blueprint</title>\n'
    printf '  </head>\n'
    printf '  <body data-cmux-webview-kind="blueprint">\n'
    printf '    <main id="root"></main>\n'
    printf '    <script>window.EXCALIDRAW_ASSET_PATH = "./excalidraw-assets/";</script>\n'
    printf '    <script type="module" src="./main.mjs"></script>\n'
    printf '  </body>\n'
    printf '</html>\n'
  } > "$out_dir/blueprint.html"
}

# Excalidraw resolves its handwriting/UI fonts at runtime relative to
# `window.EXCALIDRAW_ASSET_PATH` (`<path>fonts/<Family>/<file>.woff2`), so the
# font files ship next to the bundle instead of inside it. Xiaolai (the ~12 MB
# CJK fallback family) is left out; Excalidraw falls back to system fonts for
# glyphs it cannot find.
copy_blueprint_fonts() {
  out_dir="$1"
  fonts_src="$SRC_DIR/node_modules/@excalidraw/excalidraw/dist/prod/fonts"
  if [ ! -d "$fonts_src" ]; then
    echo "error: missing Excalidraw fonts at $fonts_src (run bun install in webviews/)" >&2
    exit 1
  fi
  fonts_out="$out_dir/excalidraw-assets/fonts"
  rm -rf "$out_dir/excalidraw-assets"
  mkdir -p "$fonts_out"
  for family_dir in "$fonts_src"/*/; do
    family="$(basename "$family_dir")"
    if [ "$family" = "Xiaolai" ]; then
      continue
    fi
    mkdir -p "$fonts_out/$family"
    cp "$family_dir"/*.woff2 "$fonts_out/$family/"
  done
}

strip_trailing_line_whitespace() {
  /usr/bin/perl -0pi -e 's/[ \t]+(?=\r?\n)//g; s/[ \t]+\z//' "$@"
}

normalize_webviews_output() {
  out_dir="$1"
  strip_trailing_line_whitespace "$out_dir/main.mjs" "$out_dir/agent-session.html" "$out_dir/blueprint.html"
}

if [ "${1:-}" = "--check" ]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  (
    cd "$SRC_DIR"
    bun install --frozen-lockfile
    CMUX_WEBVIEWS_OUT_DIR="$tmp_dir" bun run build
    write_agent_session_html "$tmp_dir"
    write_blueprint_html "$tmp_dir"
    copy_blueprint_fonts "$tmp_dir"
    normalize_webviews_output "$tmp_dir"
  )
  diff_output="$(mktemp)"
  set +e
  diff -qr "$OUT_DIR" "$tmp_dir" >"$diff_output"
  diff_status=$?
  set -e
  if [ "$diff_status" -ne 0 ]; then
    cat "$diff_output" >&2
    rm -f "$diff_output"
    if [ "$diff_status" -eq 1 ]; then
      echo "webviews app assets are stale; run ./scripts/build-webviews-app.sh" >&2
      exit 1
    fi
    echo "failed to compare webviews assets (diff exit $diff_status)" >&2
    exit 2
  fi
  rm -f "$diff_output"
  exit 0
fi

(
  cd "$SRC_DIR"
  bun install --frozen-lockfile
  bun run build
)
write_agent_session_html "$OUT_DIR"
write_blueprint_html "$OUT_DIR"
copy_blueprint_fonts "$OUT_DIR"
normalize_webviews_output "$OUT_DIR"
