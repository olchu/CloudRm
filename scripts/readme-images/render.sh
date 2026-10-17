#!/usr/bin/env bash
# Renders the README images into docs/images:
#   hero.png                - banner with the app icon
#   screenshot-overview.png - main window with sample data
#   screenshot-folder.png   - an open folder while local copies are removed
#
# The screenshots draw the real ContentView with made-up sample data, so they
# never contain anyone's actual files.
#
# Usage: scripts/readme-images/render.sh

set -euo pipefail

cd "$(dirname "$0")/../.."

BUILD_DIR="build/readme-images"
OUTPUT_DIR="docs/images"
ICON="CloudeRm/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"

mkdir -p "$BUILD_DIR"

SOURCES=()
for source in CloudeRm/*.swift; do
    [[ "$source" == */CloudeRmApp.swift ]] || SOURCES+=("$source")
done

echo "==> Compiling renderer"
# Mirrors the app target's Swift settings (MainActor default isolation,
# approachable concurrency).
xcrun swiftc \
    -parse-as-library \
    -D DEBUG \
    -swift-version 5 \
    -default-isolation MainActor \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature MemberImportVisibility \
    -target "$(uname -m)-apple-macos26.5" \
    -o "$BUILD_DIR/render" \
    "${SOURCES[@]}" \
    scripts/readme-images/RenderReadmeImages.swift

echo "==> Rendering"
# English number and date formatting regardless of the Mac's region.
"$BUILD_DIR/render" "$ICON" "$OUTPUT_DIR" -AppleLocale en_US -AppleLanguages '(en)'

# Optional: the dark UI survives 256 colors, which cuts each screenshot from
# about 2.5 MB to about 100 KB. Skipped when Pillow is not installed.
if python3 -c "import PIL" 2>/dev/null; then
    echo "==> Compressing screenshots"
    python3 -I - "$OUTPUT_DIR"/screenshot-*.png <<'PYTHON'
import sys
from PIL import Image

for path in sys.argv[1:]:
    image = Image.open(path).quantize(
        colors=256,
        method=Image.Quantize.FASTOCTREE,
        dither=Image.Dither.FLOYDSTEINBERG,
    )
    image.save(path, optimize=True)
PYTHON
fi
