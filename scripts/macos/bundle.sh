#!/usr/bin/env bash
# Assemble and sign build/Markdown.app.
#
#   scripts/macos/bundle.sh              debug, host arch, ad-hoc signed
#   scripts/macos/bundle.sh --release    release, host arch
#   scripts/macos/bundle.sh --universal  release, arm64 + x86_64 (per-arch builds, lipo'd)
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/macos/bundle.sh --release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PKG="$ROOT/apps/macos"
BUILD="$ROOT/build"
APP="$BUILD/Markdown.app"

CONFIG=debug
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --debug) CONFIG=debug ;;
    --universal) CONFIG=release; UNIVERSAL=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

export MACOSX_DEPLOYMENT_TARGET=14.0

CORE_ARGS=(--"$CONFIG")
SWIFT_ARGS=(-c "$CONFIG")
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
    swift build -c release --triple "$arch-apple-macosx14.0"
    SLICES+=("$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/Markdown")
  done
  BIN_DIR="$APP_PKG/.build/universal-release"
  mkdir -p "$BIN_DIR"
  lipo -create -output "$BIN_DIR/Markdown" "${SLICES[@]}"
else
  swift build "${SWIFT_ARGS[@]}"
  BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Markdown" "$APP/Contents/MacOS/Markdown"
cp "$APP_PKG/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp --options runtime \
    --entitlements "$APP_PKG/Resources/Markdown.entitlements" "$APP"
else
  codesign --force --sign - --timestamp=none \
    --entitlements "$APP_PKG/Resources/Markdown.entitlements" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "Bundle: $APP"
