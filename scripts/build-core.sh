#!/usr/bin/env bash
# Build markdown-ffi, generate Swift bindings, and assemble the XCFramework.
#
#   scripts/build-core.sh               host arch, debug
#   scripts/build-core.sh --release     host arch, release
#   scripts/build-core.sh --universal   arm64 + x86_64 (lipo), release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Use rustup's cargo first even if another toolchain is earlier on PATH.
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0

PROFILE=debug
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --release) PROFILE=release ;;
    --debug) PROFILE=debug ;;
    --universal) UNIVERSAL=1; PROFILE=release ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

CARGO_PROFILE_FLAG=()
[ "$PROFILE" = release ] && CARGO_PROFILE_FLAG=(--release)

case "$(uname -m)" in
  arm64) HOST_TRIPLE=aarch64-apple-darwin ;;
  x86_64) HOST_TRIPLE=x86_64-apple-darwin ;;
  *) echo "unsupported host arch $(uname -m)" >&2; exit 1 ;;
esac

if [ "$UNIVERSAL" = 1 ]; then
  TRIPLES=(aarch64-apple-darwin x86_64-apple-darwin)
else
  TRIPLES=("$HOST_TRIPLE")
fi

LIB=libmarkdown_ffi.a
for t in "${TRIPLES[@]}"; do
  echo "==> cargo build ($t, $PROFILE)"
  cargo build -p markdown-ffi --lib --target "$t" ${CARGO_PROFILE_FLAG[@]+"${CARGO_PROFILE_FLAG[@]}"}
done

# Static library to package: thin for one arch, lipo'd for universal.
if [ "$UNIVERSAL" = 1 ]; then
  OUT_LIB_DIR="target/universal/$PROFILE"
  mkdir -p "$OUT_LIB_DIR"
  lipo -create -output "$OUT_LIB_DIR/$LIB" \
    "target/aarch64-apple-darwin/$PROFILE/$LIB" \
    "target/x86_64-apple-darwin/$PROFILE/$LIB"
else
  OUT_LIB_DIR="target/${TRIPLES[0]}/$PROFILE"
fi
PKG_LIB="$OUT_LIB_DIR/$LIB"

# Bindings are generated from a thin library (bindgen cannot read fat files). The generator
# itself is a host tool and always a debug build: it only reads the library's metadata, and
# a release (LTO) build of it would cost minutes.
BINDGEN_LIB="target/${TRIPLES[0]}/$PROFILE/$LIB"
echo "==> generating Swift bindings"
GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
cargo run -q -p markdown-ffi --features cli --bin uniffi-bindgen -- \
  generate "$BINDGEN_LIB" --language swift --out-dir "$GEN"

APP="$ROOT/apps/macos"
SWIFT_DST="$APP/Sources/MarkdownCore"
XCF="$APP/Frameworks/MarkdownCoreFFI.xcframework"

mkdir -p "$SWIFT_DST"
rm -f "$SWIFT_DST"/*.swift
cp "$GEN/markdown_ffi.swift" "$SWIFT_DST/markdown_ffi.swift"

echo "==> assembling XCFramework"
HDR="$GEN/Headers"
mkdir -p "$HDR"
cp "$GEN/markdown_ffiFFI.h" "$HDR/"
cp "$GEN/markdown_ffiFFI.modulemap" "$HDR/module.modulemap"

rm -rf "$XCF"
mkdir -p "$APP/Frameworks"
xcodebuild -create-xcframework -library "$PKG_LIB" -headers "$HDR" -output "$XCF" >/dev/null

echo "XCFramework: $XCF"
lipo -info "$PKG_LIB"
