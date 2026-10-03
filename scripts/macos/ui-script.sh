#!/usr/bin/env bash
# Run a UI script against the real app (no Accessibility permission needed: the app drives
# itself). Writes PNG snapshots and log.json to the output directory and exits non-zero if any
# assertion failed.
#
#   scripts/macos/ui-script.sh scripts/macos/ui/smoke.json            # debug bundle
#   scripts/macos/ui-script.sh scripts/macos/ui/smoke.json out/dir    # choose the output dir
#   RELEASE=1 scripts/macos/ui-script.sh scripts/macos/ui/big.json    # release build (timings)
#   SKIP_BUILD=1 ...                                                  # reuse build/Markdown.app
#   UI_BUILD=/some/dir ...      # build and run DIR/Markdown.app instead (leaves build/Markdown.app alone)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ $# -ge 1 ] || { sed -n '2,11p' "$0"; exit 2; }
SCRIPT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="${2:-$ROOT/build/ui/$(basename "$1" .json)}"
UI_BUILD="${UI_BUILD:-$ROOT/build}"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  mkdir -p "$UI_BUILD"
  ARGS=(--out "$UI_BUILD")
  [ "${RELEASE:-0}" = 1 ] && ARGS+=(--release --ui-script)
  if ! "$ROOT/scripts/macos/bundle.sh" "${ARGS[@]}" >"$UI_BUILD/ui-script-build.log" 2>&1; then
    tail -40 "$UI_BUILD/ui-script-build.log" >&2
    exit 1
  fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"
# Wake the display (snapshots of a sleeping display can come out black).
caffeinate -u -t 3 >/dev/null 2>&1 &
"$UI_BUILD/Markdown.app/Contents/MacOS/Markdown" \
  --ui-script "$SCRIPT" --ui-out "$OUT" --ui-root "$ROOT" \
  -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO
