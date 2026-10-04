#!/usr/bin/env bash
# Give "examples/History Demo.md" a history to try the History panel on (View > History, ⌃⌘H). The app
# derives the file's key itself, as a normal open does, writes eight versions spread over the last ten days
# into its real store (~/Library/Application Support/Markdown/history) and exits. Running it again records
# nothing new. Quit the app first: the script refuses to run while one is open.
#
#   scripts/macos/seed-history-demo.sh                  # build/Markdown.app
#   UI_BUILD=/some/dir scripts/macos/seed-history-demo.sh   # DIR/Markdown.app instead
#   scripts/macos/seed-history-demo.sh path/to/Other.md     # another file (it must match history-demo.json's final text to look right)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UI_BUILD="${UI_BUILD:-$ROOT/build}"
BIN="$UI_BUILD/Markdown.app/Contents/MacOS/Markdown"
VERSIONS="$ROOT/scripts/macos/history-demo/history-demo.json"
FILE="${1:-$ROOT/examples/History Demo.md}"

[ -x "$BIN" ] || { echo "no app at $UI_BUILD/Markdown.app (build it, or set UI_BUILD)" >&2; exit 1; }
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

if pgrep -f "Contents/MacOS/Markdown( |\$)" >/dev/null; then
  echo "Markdown is running. Quit it first, so two stores do not write one folder, then run this again." >&2
  exit 1
fi

echo "file:  $FILE"
"$BIN" --seed-history "$FILE" --seed-versions "$VERSIONS"
