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
# The guide and the acknowledgements: what the Help menu points at; and the page the Templates window shows.
for f in Welcome.md Acknowledgements.md "Template Sample.md"; do
  [ -f "$APP_PKG/Resources/$f" ] || { echo "bundle: missing $APP_PKG/Resources/$f" >&2; exit 1; }
  cp "$APP_PKG/Resources/$f" "$APP/Contents/Resources/$f"
done
# The app icon (documents keep the system's plain one). macOS 11 to 15 read Markdown.icns
# (CFBundleIconFile); macOS 26 reads the Liquid Glass icon from Assets.car (CFBundleIconName), which
# actool compiles from the Icon Composer package assets/Markdown.icon whenever it is there.
ICNS="$ROOT/assets/macOS-11-to-15/AppIcon.icns"
ICON_PKG="$ROOT/assets/Markdown.icon"
[ -f "$ICNS" ] || { echo "bundle: missing $ICNS" >&2; exit 1; }
cp "$ICNS" "$APP/Contents/Resources/Markdown.icns"
if [ -d "$ICON_PKG" ]; then
  echo "==> actool $(basename "$ICON_PKG")"
  ICON_TMP="$(mktemp -d)"
  # (`xcrun actool` needs Xcode itself, not only the command-line tools.)
  if ! ACTOOL_LOG="$(xcrun actool "$ICON_PKG" --compile "$ICON_TMP" --app-icon Markdown \
        --platform macosx --target-device mac --minimum-deployment-target "$MACOSX_DEPLOYMENT_TARGET" \
        --output-partial-info-plist "$ICON_TMP/partial.plist" \
        --output-format human-readable-text --notices --warnings --errors 2>&1)"; then
    echo "$ACTOOL_LOG" >&2
    echo "bundle: actool failed on $ICON_PKG" >&2
    exit 1
  fi
  # Anything actool or the SVG renderer complains about is a broken icon, not noise.
  if echo "$ACTOOL_LOG" | grep -E -i 'warning|error|notice:' | grep -v '^/\* com.apple.actool' >&2; then
    echo "bundle: actool reported problems with $ICON_PKG (above)" >&2
    exit 1
  fi
  [ "$(plutil -extract CFBundleIconName raw -o - "$ICON_TMP/partial.plist")" = Markdown ] \
    || { echo "bundle: actool did not name the icon Markdown" >&2; exit 1; }
  cp "$ICON_TMP/Assets.car" "$APP/Contents/Resources/Assets.car"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Markdown" "$APP/Contents/Info.plist"
  plutil -lint "$APP/Contents/Info.plist" >/dev/null
  rm -rf "$ICON_TMP"
fi
# Bundled writing fonts (SIL OFL) and their license; the app falls back to system
# fonts when they are missing. Info.plist's ATSApplicationFontsPath points at this folder.
if [ -d "$APP_PKG/Resources/Fonts" ]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp "$APP_PKG"/Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
else
  echo "warning: $APP_PKG/Resources/Fonts missing; the app will use system fonts" >&2
fi
# The built-in templates (read-only packages; the app lists them beside the user's own). The core's copies in
# crates/markdown-core/templates are the source of truth: ReleaseTests fails when these differ from them.
[ -d "$APP_PKG/Resources/Templates" ] || { echo "bundle: missing $APP_PKG/Resources/Templates" >&2; exit 1; }
mkdir -p "$APP/Contents/Resources/Templates"
cp -R "$APP_PKG"/Resources/Templates/*.mdtemplate "$APP/Contents/Resources/Templates/"
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
