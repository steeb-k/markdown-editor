#!/usr/bin/env bash
# Wrap a built Markdown.app in a compressed, read-only disk image.
#
#   scripts/macos/make-dmg.sh build/Markdown.app              -> build/Markdown-<version>.dmg
#   scripts/macos/make-dmg.sh build/Markdown.app out.dmg      -> out.dmg
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/macos/make-dmg.sh build/Markdown.app
#
# The image (volume name "Markdown") holds the app and a symlink to /Applications. The app is
# copied with ditto, which keeps the signature, symlinks and extended attributes a plain cp can
# lose. With CODESIGN_IDENTITY set the image itself is signed too (Gatekeeper looks at the image
# before it looks inside); the app inside must already be signed, this script does not sign it.
# It does not notarize: scripts/macos/release.sh does that after this.
#
# Idempotent: an existing output is replaced. Deterministic in what matters (same app, same file
# names, same layout, modification times fixed to the app's build); hdiutil itself stamps a new
# volume UUID and creation date into every image, so two runs are not byte-for-byte equal.
set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { sed -n '2,6p' "$0" >&2; exit 2; }
[ -d "$APP/Contents" ] || { echo "make-dmg: not an app bundle: $APP" >&2; exit 1; }
APP="$(cd "$APP" && pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
OUT="${2:-$ROOT/build/Markdown-$VERSION.dmg}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
VOLNAME="Markdown"

codesign --verify --strict "$APP" 2>/dev/null || { echo "make-dmg: the app's signature does not verify; sign it first (scripts/macos/bundle.sh)" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/markdown-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Markdown.app"
ln -s /Applications "$STAGE/Applications"
# One timestamp for everything: the executable's, so a rebuild is a new image and a re-run is not.
STAMP="$(stat -f %Sm -t %Y%m%d%H%M.%S "$APP/Contents/MacOS/Markdown")"
find "$STAGE" -exec touch -h -t "$STAMP" {} +

rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$OUT"
  codesign --verify --strict --verbose=2 "$OUT"
  echo "make-dmg: signed with the Developer ID identity"
else
  echo "make-dmg: NOT signed (CODESIGN_IDENTITY is not set)" >&2
fi
echo "make-dmg: wrote $OUT ($(du -h "$OUT" | awk '{print $1}'))"
