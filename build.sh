#!/bin/bash
# Build ReSign.app and launch it for fast iteration.
#
# Usage:
#   ./build.sh                 # fast: Debug build, run from ./build (default)
#   ./build.sh --install       # Release build, install to /Applications, relaunch
#   ./build.sh -v              # verbose xcodebuild output
#   ./build.sh -h              # show this help

set -euo pipefail

APP_NAME=ReSign
MODE=fast   # fast | install
VERBOSE=0

for arg in "$@"; do
    case "$arg" in
        --install)       MODE=install ;;
        -v|--verbose)    VERBOSE=1 ;;
        -h|--help)
            cat <<'EOF'
Build ReSign.app and launch it for fast iteration.

Usage:
  ./build.sh                 fast: Debug build, run from ./build (default)
  ./build.sh --install       Release build, install to /Applications, relaunch
  ./build.sh -v              verbose xcodebuild output
  ./build.sh -h              show this help
EOF
            exit 0
            ;;
        *)
            echo "error: unknown flag '$arg'. Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

cd "$(dirname "$0")"

# 1. Regenerate project (only if project.yml exists — ReSign may not use xcodegen)
if [ -f "project.yml" ]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "error: xcodegen not installed. Install with: brew install xcodegen"
        exit 1
    fi
    echo "→ xcodegen generate"
    xcodegen generate --quiet
fi

# 2. Build
if [ "$MODE" = "fast" ]; then
    CONFIG=Debug
    # Persistent derived data for incremental builds — do NOT clean.
    DERIVED_DATA="$PWD/build/DerivedData"
    mkdir -p "$DERIVED_DATA"
    CLEAN_ARGS=()
else
    CONFIG=Release
    # Ephemeral for install — clean room.
    DERIVED_DATA=$(mktemp -d)
    trap 'rm -rf "$DERIVED_DATA"' EXIT
    CLEAN_ARGS=(clean)
fi

echo "→ xcodebuild ($APP_NAME, $CONFIG)"
XCB_ARGS=(
    -project "$APP_NAME.xcodeproj"
    -scheme "$APP_NAME"
    -configuration "$CONFIG"
    -destination 'generic/platform=macOS'
    -derivedDataPath "$DERIVED_DATA"
    -allowProvisioningUpdates
    ${CLEAN_ARGS[@]+"${CLEAN_ARGS[@]}"}
    build
)

if [ "$VERBOSE" = "1" ]; then
    xcodebuild "${XCB_ARGS[@]}"
elif command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${XCB_ARGS[@]}" | xcbeautify
else
    xcodebuild "${XCB_ARGS[@]}" 2>&1 \
        | grep -E "(error|warning): |\*\* BUILD (SUCCEEDED|FAILED) \*\*" \
        || true
fi

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIG/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "error: .app not found at $APP_PATH. Re-run with -v to see full xcodebuild output."
    exit 1
fi

# 3. Launch
if [ "$MODE" = "fast" ]; then
    # Kill only the previously-launched-from-build instance. Leave any
    # /Applications/ReSign.app or Xcode-debugged copy alone.
    BUILD_PATTERN="$PWD/build/DerivedData/.*$APP_NAME.app/Contents/MacOS/$APP_NAME"
    if pgrep -f "$BUILD_PATTERN" >/dev/null; then
        echo "→ Stopping previous ./build instance"
        pkill -f "$BUILD_PATTERN" 2>/dev/null || true
        # Wait up to 3s for graceful exit
        for _ in 1 2 3 4 5 6; do
            pgrep -f "$BUILD_PATTERN" >/dev/null || break
            sleep 0.5
        done
        # Force-kill any stragglers
        if pgrep -f "$BUILD_PATTERN" >/dev/null; then
            pkill -9 -f "$BUILD_PATTERN" 2>/dev/null || true
        fi
        # Poll until the process is truly gone — avoids LaunchServices -600
        # ("app still registered") on the subsequent `open`.
        for _ in 1 2 3 4 5 6 7 8; do
            pgrep -f "$BUILD_PATTERN" >/dev/null || break
            sleep 0.25
        done
        # Small extra beat for LaunchServices to deregister the old bundle.
        sleep 0.5
    fi

    echo "→ Launching $APP_PATH"
    open "$APP_PATH"
    echo "✓ $APP_NAME running from ./build. Check the menu bar."
else
    # Install mode: stage, quit any running copy, replace /Applications, relaunch.
    OUT_DIR="build"
    mkdir -p "$OUT_DIR"
    rm -rf "$OUT_DIR/$APP_NAME.app"
    cp -R "$APP_PATH" "$OUT_DIR/"
    echo "✓ Staged: $OUT_DIR/$APP_NAME.app"

    echo "→ Stopping any running $APP_NAME..."
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null || break
        sleep 0.5
    done

    if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
        echo "  (forcing quit — app did not respond to AppleScript)"
        pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
        sleep 0.5
    fi

    if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
        pkill -9 -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
        sleep 0.3
    fi

    if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
        if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" | xargs -I{} ps -p {} -o stat= 2>/dev/null | grep -q X; then
            echo "error: $APP_NAME is being held by Xcode's debugger (status 'X'). Switch to Xcode and hit Product → Stop (⌘.) or quit Xcode, then re-run ./build.sh --install."
        else
            echo "error: $APP_NAME survived SIGTERM + SIGKILL. Run 'pgrep -fl $APP_NAME' to inspect, then kill manually."
        fi
        exit 1
    fi

    echo "→ Installing to /Applications/$APP_NAME.app"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$OUT_DIR/$APP_NAME.app" /Applications/

    echo "→ Launching..."
    open "/Applications/$APP_NAME.app"
    echo "✓ $APP_NAME running from /Applications. Check the menu bar."
fi
