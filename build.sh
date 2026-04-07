#!/bin/bash
set -e

APP_NAME=ReSign
DERIVED_DATA=$(mktemp -d)
OUT_DIR="$(dirname "$0")/build"

echo "Building $APP_NAME..."
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates

APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "error: .app not found at $APP_PATH"
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/$APP_NAME.app"
cp -R "$APP_PATH" "$OUT_DIR/"
rm -rf "$DERIVED_DATA"

echo ""
echo "Build succeeded: $OUT_DIR/$APP_NAME.app"
echo ""
echo "To install, run:"
echo "  cp -R \"$OUT_DIR/$APP_NAME.app\" /Applications/"
