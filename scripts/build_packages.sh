#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/outputs"

echo "=== H3kbHook Build Script ==="
echo "Project: $PROJECT_DIR"
echo "Output:  $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"

# ── rootful ──────────────────────────────────────────────────────
echo ""
echo "── Building rootful ──"
cd "$PROJECT_DIR"
make clean package THEOS_PACKAGE_SCHEME=

ROOTFUL_DEB=$(find "$PROJECT_DIR/rootful" -maxdepth 1 -name '*.deb' -print -quit)
if [ -z "$ROOTFUL_DEB" ]; then
    echo "ERROR: rootful .deb not found"
    exit 1
fi
# Replace arch suffix with iphoneos-arm for rootful
ROOTFUL_OUT="$OUTPUT_DIR/$(basename "$ROOTFUL_DEB" | sed 's/iphoneos-arm64/iphoneos-arm/')"
cp "$ROOTFUL_DEB" "$ROOTFUL_OUT"
echo "rootful: $(basename "$ROOTFUL_OUT") → outputs/"

# ── rootless ─────────────────────────────────────────────────────
echo ""
echo "── Building rootless ──"
cd "$PROJECT_DIR"
make clean package THEOS_PACKAGE_SCHEME=rootless

ROOTLESS_DEB=$(find "$PROJECT_DIR/rootless" -maxdepth 1 -name '*.deb' -print -quit)
if [ -z "$ROOTLESS_DEB" ]; then
    echo "ERROR: rootless .deb not found"
    exit 1
fi
cp "$ROOTLESS_DEB" "$OUTPUT_DIR/"
echo "rootless: $(basename "$ROOTLESS_DEB") → outputs/"

# ── roothide ─────────────────────────────────────────────────────
echo ""
echo "── Building roothide ──"
cd "$PROJECT_DIR"
make clean package THEOS_PACKAGE_SCHEME=roothide

ROOTHIDE_DEB=$(find "$PROJECT_DIR/roothide" -maxdepth 1 -name '*.deb' -print -quit)
if [ -z "$ROOTHIDE_DEB" ]; then
    echo "ERROR: roothide .deb not found"
    exit 1
fi
cp "$ROOTHIDE_DEB" "$OUTPUT_DIR/"
echo "roothide: $(basename "$ROOTHIDE_DEB") → outputs/"

# ── verify ───────────────────────────────────────────────────────
echo ""
echo "=== Build Complete ==="
echo "Packages in $OUTPUT_DIR/:"
echo ""
for deb in "$OUTPUT_DIR"/*.deb; do
    echo "── $(basename "$deb") ──"
    dpkg-deb -I "$deb" 2>/dev/null | grep -E "Package:|Version:|Architecture:" || true
    echo "  Paths:"
    dpkg-deb -c "$deb" 2>/dev/null | grep -E "\.dylib|\.plist" | sed 's/^/    /'
    echo ""
done
