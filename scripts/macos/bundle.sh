#!/usr/bin/env bash
# Assemble and sign build/Markdown.app. The one place the bundle is put together.
#
#   scripts/macos/bundle.sh              debug, host arch, ad-hoc signed
#   scripts/macos/bundle.sh --release    release, host arch
#   scripts/macos/bundle.sh --universal  release, arm64 + x86_64 (per-arch builds, lipo'd)
#   scripts/macos/bundle.sh --release --ui-script   release with the UI-script harness compiled in
#                                        (debug builds always have it; see scripts/macos/ui/README.md)
#   scripts/macos/bundle.sh --out DIR    assemble DIR/Markdown.app instead of build/Markdown.app
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/macos/bundle.sh --release --universal
#
# Signing: ad-hoc unless CODESIGN_IDENTITY names a certificate. Either way the hardened runtime is
# on, so what runs here is what runs signed; a real identity adds the secure timestamp. The build
# number (CFBundleVersion) is the number of commits in the checkout, or 1 outside one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PKG="$ROOT/apps/macos"
BUILD="$ROOT/build"

CONFIG=debug
UNIVERSAL=0
UI_SCRIPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --release) CONFIG=release ;;
    --debug) CONFIG=debug ;;
    --universal) CONFIG=release; UNIVERSAL=1 ;;
    --ui-script) UI_SCRIPT=1 ;;
    --out) [ $# -ge 2 ] || { echo "bundle: --out needs a directory" >&2; exit 2; }; BUILD="$2"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "bundle: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
mkdir -p "$BUILD"
BUILD="$(cd "$BUILD" && pwd)"
APP="$BUILD/Markdown.app"

export MACOSX_DEPLOYMENT_TARGET=14.0

CORE_ARGS=(--"$CONFIG")
SWIFT_ARGS=(-c "$CONFIG")
if [ "$UI_SCRIPT" = 1 ]; then
  SWIFT_ARGS+=(-Xswiftc -DUI_SCRIPT)
fi
if [ "$UNIVERSAL" = 1 ]; then
  CORE_ARGS=(--universal)
fi

"$ROOT/scripts/build-core.sh" "${CORE_ARGS[@]}"

echo "==> swift build"
cd "$APP_PKG"
if [ "$UNIVERSAL" = 1 ]; then
  # `swift build --arch arm64 --arch x86_64` switches to the XCBuild backend, which
  # cannot link the static-library XCFramework ("library not found for -lmarkdown_ffi").
  # Build each slice with the native backend via --triple and lipo them instead.
  SLICES=()
  for arch in arm64 x86_64; do
    swift build "${SWIFT_ARGS[@]}" --triple "$arch-apple-macosx14.0"
    SLICES+=("$(swift build "${SWIFT_ARGS[@]}" --triple "$arch-apple-macosx14.0" --show-bin-path)/Markdown")
  done
  BIN_DIR="$APP_PKG/.build/universal-release"
  mkdir -p "$BIN_DIR"
  lipo -create -output "$BIN_DIR/Markdown" "${SLICES[@]}"
else
  swift build "${SWIFT_ARGS[@]}"
  BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
fi

# The build number: commits in this checkout (a number, as CFBundleVersion must be), else 1.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
case "$BUILD_NUMBER" in ''|*[!0-9]*) BUILD_NUMBER=1 ;; esac

echo "==> assembling $APP (build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Markdown" "$APP/Contents/MacOS/Markdown"
cp "$APP_PKG/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The icons, the guide and the acknowledgements: what Info.plist and the Help menu point at.
for f in Markdown.icns MarkdownDocument.icns Welcome.md Acknowledgements.md; do
  [ -f "$APP_PKG/Resources/$f" ] || { echo "bundle: missing $APP_PKG/Resources/$f" >&2; exit 1; }
  cp "$APP_PKG/Resources/$f" "$APP/Contents/Resources/$f"
done
# Bundled writing fonts (the reference editor, SIL OFL) and their license; the app falls back to system
# fonts when they are missing. Info.plist's ATSApplicationFontsPath points at this folder.
if [ -d "$APP_PKG/Resources/Fonts" ]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp "$APP_PKG"/Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
else
  echo "warning: $APP_PKG/Resources/Fonts missing; the app will use system fonts" >&2
fi
# Nothing may ride along that signing trips over: Finder litter, quarantine and other extended attributes.
find "$APP" -name .DS_Store -delete
xattr -cr "$APP"

echo "==> signing"
ENTITLEMENTS="$APP_PKG/Resources/Markdown.entitlements"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  SIGN=(--sign "$CODESIGN_IDENTITY" --timestamp --options runtime)
else
  SIGN=(--sign - --timestamp=none --options runtime)
fi
# Nested code first, the bundle last, and never --deep (deprecated: it signs in an order of its
# own and hides which file a failure came from). Today the bundle has no nested code (the Rust
# core is a static library inside the executable), so this finds nothing; it is here so that a
# future helper or framework is signed before the bundle that contains it.
while IFS= read -r -d '' nested; do
  case "$nested" in "$APP/Contents/MacOS/Markdown") continue ;; esac
  if file -b "$nested" | grep -q 'Mach-O'; then
    echo "   nested: ${nested#"$APP"/}"
    codesign --force "${SIGN[@]}" "$nested"
  fi
done < <(find "$APP/Contents" -type f -print0)
codesign --force "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "--- entitlements:"
codesign -d --entitlements - "$APP" 2>&1 | sed 's/^/    /'

echo "Bundle: $APP"
