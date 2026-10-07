#!/usr/bin/env bash
# Check that a Markdown.app contains what a release should and nothing else.
#
#   scripts/macos/verify-bundle.sh build/Markdown.app [--universal] [--no-harness]
#
#   --universal    both slices (arm64, x86_64), each with a minimum OS of 14.0
#   --no-harness   no UI-script code in the binary (a release build made without --ui-script)
#
# Prints what it checked; exits non-zero on the first thing that is wrong.
set -euo pipefail

APP=""
UNIVERSAL=0
NO_HARNESS=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --no-harness) NO_HARNESS=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    -*) echo "verify-bundle: unknown option: $arg" >&2; exit 2 ;;
    *) APP="$arg" ;;
  esac
done
[ -n "$APP" ] || { sed -n '2,9p' "$0" >&2; exit 2; }
[ -d "$APP/Contents" ] || { echo "verify-bundle: not a bundle: $APP" >&2; exit 1; }
APP="$(cd "$APP" && pwd)"
fail() { echo "verify-bundle: FAIL: $*" >&2; exit 1; }
ok() { echo "  ok  $*"; }

echo "==> $APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist does not lint"
plist() { plutil -extract "$1" raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION="$(plist CFBundleShortVersionString)"; BUILD="$(plist CFBundleVersion)"
case "$BUILD" in ''|*[!0-9]*) fail "CFBundleVersion is not a number: '$BUILD'" ;; esac
[ "$(plist CFBundleIconFile)" = Markdown ] || fail "CFBundleIconFile is not Markdown"
[ "$(plist CFBundleIconName)" = Markdown ] || fail "CFBundleIconName is not Markdown (the macOS 26 icon in Assets.car)"
# Documents use the system's plain document icon.
if plutil -convert xml1 -o - "$APP/Contents/Info.plist" | grep -q -E '<key>(CFBundleTypeIconFile|CFBundleTypeIconFiles|UTTypeIconFile|UTTypeIcons)</key>'; then
  fail "a document type names an icon of its own"
fi
[ "$(plist LSMinimumSystemVersion)" = 14.0 ] || fail "LSMinimumSystemVersion is not 14.0"
ok "Info.plist lints; version $VERSION, build $BUILD"

# The exact list of files. Fonts: the twelve faces and their license. Templates: the four built-in packages.
EXPECTED="$(mktemp)"; ACTUAL="$(mktemp)"
trap 'rm -f "$EXPECTED" "$ACTUAL"' EXIT
{
  echo "Contents/Info.plist"
  echo "Contents/MacOS/Markdown"
  echo "Contents/PkgInfo"
  echo "Contents/Resources/Acknowledgements.md"
  echo "Contents/Resources/Assets.car"
  echo "Contents/Resources/Markdown.icns"
  echo "Contents/Resources/Welcome.md"
  echo "Contents/Resources/Template Sample.md"
  echo "Contents/Resources/Fonts/OFL-LICENSE.md"
  for t in Academic Default Letter Typewriter; do echo "Contents/Resources/Templates/${t}.mdtemplate/template.toml"; done
  for fam in Duo Mono Quattro; do
    for face in Regular Italic Bold BoldItalic; do echo "Contents/Resources/Fonts/iAWriter${fam}S-${face}.ttf"; done
  done
  echo "Contents/_CodeSignature/CodeResources"
} | sort > "$EXPECTED"
(cd "$APP" && find . -type f | sed 's|^\./||' | sort) > "$ACTUAL"
if ! diff -u "$EXPECTED" "$ACTUAL" >&2; then fail "the bundle's files are not the intended list (see the diff above)"; fi
ok "contents are exactly the intended $(wc -l < "$ACTUAL" | tr -d ' ') files"
[ -z "$(find "$APP" -name .DS_Store)" ] || fail ".DS_Store inside the bundle"
# com.apple.provenance is the system's own record of which app wrote a file; it is put back on every
# file a process creates, signing does not look at it, and it cannot be kept off. Anything else is a problem.
XATTRS="$(xattr -r "$APP" 2>/dev/null | grep -v 'com.apple.provenance' || true)"
[ -z "$XATTRS" ] || fail "extended attributes inside the bundle: $(echo "$XATTRS" | head -3)"
ok "no .DS_Store, no extended attributes (other than the system's provenance mark)"
[ "$(cat "$APP/Contents/PkgInfo")" = "APPL????" ] || fail "PkgInfo is not APPL????"

# The icon: an .icns with every size (macOS 11 to 15), and a layered icon named Markdown in Assets.car (26).
ICONSET="$(mktemp -d)/Markdown.iconset"
iconutil -c iconset -o "$ICONSET" "$APP/Contents/Resources/Markdown.icns" 2>/dev/null || fail "Markdown.icns is not a valid icon file"
# (The 16 and 32 pt sizes at 1x are optional: the system scales the 2x images down for them.)
for name in 16x16@2x 32x32@2x 128x128 128x128@2x 256x256 256x256@2x 512x512 512x512@2x; do
  [ -f "$ICONSET/icon_${name}.png" ] || fail "Markdown.icns lacks the ${name} image"
done
rm -rf "$(dirname "$ICONSET")"
STACKS="$(xcrun assetutil --info "$APP/Contents/Resources/Assets.car" 2>/dev/null | python3 -c '
import json, sys
print(sum(1 for e in json.load(sys.stdin) if e.get("AssetType") == "IconImageStack" and e.get("Name") == "Markdown"))' || echo 0)"
[ "${STACKS:-0}" -ge 1 ] || fail "Assets.car has no layered icon named Markdown"
ok "icon: Markdown.icns with all its sizes; Assets.car holds the layered icon ($STACKS appearances)"

BIN="$APP/Contents/MacOS/Markdown"
ARCHS="$(lipo -archs "$BIN")"
if [ "$UNIVERSAL" = 1 ]; then
  case " $ARCHS " in *" arm64 "*) ;; *) fail "no arm64 slice: $ARCHS" ;; esac
  case " $ARCHS " in *" x86_64 "*) ;; *) fail "no x86_64 slice: $ARCHS" ;; esac
  for arch in arm64 x86_64; do
    minos="$(vtool -arch "$arch" -show-build "$BIN" | awk '$1=="minos"{print $2}')"
    [ "$minos" = 14.0 ] || fail "$arch slice has minos '$minos', not 14.0"
  done
  ok "universal ($ARCHS), minos 14.0 in both slices"
else
  ok "architectures: $ARCHS"
fi

if [ "$NO_HARNESS" = 1 ]; then
  # Counted, not `grep -q`: under pipefail, grep -q stops reading at the first match, `strings` dies
  # of SIGPIPE and the pipeline "fails", which turned every match into a pass.
  HITS="$(strings -a "$BIN" | grep -c -E 'UIScriptRunner|--ui-script|MARKDOWN_UI_SCRIPT|UI_SCRIPT_ALLOW_NAP' || true)"
  [ "${HITS:-0}" = 0 ] || fail "the binary contains UI-harness code ($HITS strings)"
  SYMS="$(nm "$BIN" 2>/dev/null | grep -c 'UIScript' || true)"
  [ "${SYMS:-0}" = 0 ] || fail "the binary has UIScript symbols ($SYMS)"
  ok "no UI-harness strings or symbols in the binary"
fi

# Signature, as far as it goes without an identity.
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/      /'
FLAGS="$(codesign -dv "$APP" 2>&1 | grep -E '^CodeDirectory' || true)"
case "$FLAGS" in *runtime*) ok "signature valid, hardened runtime on ($FLAGS)" ;; *) fail "hardened runtime flag missing: $FLAGS" ;; esac
# The signed entitlements are the file's (none): in particular no get-task-allow, which a debug
# signature carries and the notary service rejects.
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
case "$ENTS" in *"<key>"*) fail "the signature carries entitlements: $ENTS" ;; esac
ok "no entitlements in the signature"
echo "==> bundle OK"
