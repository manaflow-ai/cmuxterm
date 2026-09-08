#!/usr/bin/env bash
# Behavioral test for tests/test_ci_sparkle_build_monotonic.sh.
#
# release.yml runs that guard at the top of build-sign-notarize. A tag push must
# fail on a stale build number (Sparkle would never offer the update), but a
# non-tag workflow_dispatch is the pipeline's dry run: it publishes nothing and
# runs from a branch that has not been bumped, so the same condition must only
# warn there (https://github.com/manaflow-ai/cmux/issues/12149). Exercise both
# modes against fixture project files and a local appcast.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

project_with_build() {
  local build="$1"
  local file="$TMP_DIR/project-$build.pbxproj"
  cat > "$file" <<PBX
		CURRENT_PROJECT_VERSION = $build;
		MARKETING_VERSION = 0.64.22;
		CURRENT_PROJECT_VERSION = $build;
PBX
  printf '%s' "$file"
}

APPCAST="$TMP_DIR/appcast.xml"
cat > "$APPCAST" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>0.64.22</title>
      <sparkle:version>250</sparkle:version>
      <sparkle:shortVersionString>0.64.22</sparkle:shortVersionString>
    </item>
  </channel>
</rss>
XML

run_guard() {
  local mode="$1" project="$2" appcast="$3"
  CMUX_SPARKLE_MONOTONIC_MODE="$mode" \
  CMUX_SPARKLE_PROJECT_FILE="$project" \
  CMUX_SPARKLE_APPCAST_URL="$appcast" \
    "$GUARD"
}

STALE="$(project_with_build 250)"
FRESH="$(project_with_build 251)"

# Tag push semantics: a stale build number fails.
if output="$(run_guard enforce "$STALE" "file://$APPCAST" 2>&1)"; then
  echo "FAIL: enforce mode accepted CURRENT_PROJECT_VERSION equal to the published build" >&2
  exit 1
fi
if ! grep -q "must be strictly greater than" <<<"$output"; then
  echo "FAIL: enforce mode did not explain the stale build number: $output" >&2
  exit 1
fi

# The default is enforce, so callers that pass no mode (release-pretag-guard.sh) still fail.
if CMUX_SPARKLE_PROJECT_FILE="$STALE" CMUX_SPARKLE_APPCAST_URL="file://$APPCAST" "$GUARD" >/dev/null 2>&1; then
  echo "FAIL: the guard must enforce by default" >&2
  exit 1
fi

# Dry-run semantics: the same stale build number only warns and exits 0.
if ! output="$(run_guard warn "$STALE" "file://$APPCAST" 2>&1)"; then
  echo "FAIL: warn mode must not fail on a stale build number: $output" >&2
  exit 1
fi
if ! grep -q "^WARN: CURRENT_PROJECT_VERSION (250) is not greater than" <<<"$output"; then
  echo "FAIL: warn mode did not report the stale build number: $output" >&2
  exit 1
fi
if ! grep -q "PASS (warn mode)" <<<"$output"; then
  echo "FAIL: warn mode did not report its tolerated pass: $output" >&2
  exit 1
fi

# A bumped build number passes in both modes.
for mode in enforce warn; do
  if ! output="$(run_guard "$mode" "$FRESH" "file://$APPCAST" 2>&1)"; then
    echo "FAIL: $mode mode rejected a bumped build number: $output" >&2
    exit 1
  fi
  if ! grep -q "^PASS: local CURRENT_PROJECT_VERSION=251 > published Sparkle build=250" <<<"$output"; then
    echo "FAIL: $mode mode did not report the monotonic pass: $output" >&2
    exit 1
  fi
done

# An unreachable appcast still soft-passes so offline runners never block unrelated work.
if ! output="$(run_guard enforce "$STALE" "file://$TMP_DIR/missing-appcast.xml" 2>&1)"; then
  echo "FAIL: unreachable appcast must soft-pass: $output" >&2
  exit 1
fi
if ! grep -q "PASS (soft)" <<<"$output"; then
  echo "FAIL: unreachable appcast did not soft-pass: $output" >&2
  exit 1
fi

# An unknown mode is a configuration error, never a silent pass.
if run_guard sometimes "$FRESH" "file://$APPCAST" >/dev/null 2>&1; then
  echo "FAIL: an unknown CMUX_SPARKLE_MONOTONIC_MODE must fail" >&2
  exit 1
fi

# release.yml must select the mode from the ref: enforce on tags, warn otherwise.
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
if ! grep -Fq "CMUX_SPARKLE_MONOTONIC_MODE: \${{ startsWith(github.ref, 'refs/tags/') && 'enforce' || 'warn' }}" "$RELEASE_WORKFLOW"; then
  echo "FAIL: release.yml must run the monotonic guard in enforce mode for tags and warn mode for dry runs" >&2
  exit 1
fi

echo "PASS: Sparkle monotonic guard enforces for tag pushes and warns for dry runs"
