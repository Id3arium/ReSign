#!/bin/bash
# Cut a GitHub release for the current version of ReSign.
#
# Reads the version from MARKETING_VERSION in the Xcode project (the single
# source of truth), tags it v<version>, builds a fresh Release .app, zips it,
# and creates a GitHub release with auto-generated notes and the zip attached.
#
# Usage:
#   ./release.sh          # build, tag, and publish the release
#   ./release.sh -h       # this help
#
# Safety: refuses to run on a dirty or unpushed tree, and won't overwrite an
# existing version. To release a new version, bump MARKETING_VERSION in
# ReSign.xcodeproj/project.pbxproj first, commit, and push.

set -e

APP_NAME=ReSign

case "${1:-}" in
    -h|--help)
        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "") ;;
    *)
        echo "error: unknown flag '$1'. Run '$0 --help' for usage."
        exit 1
        ;;
esac

cd "$(dirname "$0")"

# --- Preflight: tooling ---
if ! command -v gh >/dev/null 2>&1; then
    echo "error: GitHub CLI (gh) not installed. Install with: brew install gh, then run 'gh auth login'."
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "error: not signed in to GitHub CLI. Run 'gh auth login' (GitHub.com → HTTPS → browser), then re-run ./release.sh."
    exit 1
fi

# --- Read the version (single source of truth) ---
# ReSign doesn't use xcodegen/project.yml, so the version lives in the pbxproj.
VERSION=$(grep -E 'MARKETING_VERSION' ReSign.xcodeproj/project.pbxproj | head -1 | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d '"' | xargs)
if [ -z "$VERSION" ]; then
    echo "error: couldn't read MARKETING_VERSION from ReSign.xcodeproj/project.pbxproj. Confirm a line 'MARKETING_VERSION = x.y;' exists."
    exit 1
fi
TAG="v$VERSION"

# --- Safety: clean, pushed tree ---
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree has uncommitted changes. Commit or stash them so the release tag matches what's published, then re-run ./release.sh."
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch --quiet origin "$BRANCH" 2>/dev/null || true
if [ -n "$(git log "origin/$BRANCH..HEAD" --oneline 2>/dev/null)" ]; then
    echo "error: local commits aren't pushed to origin/$BRANCH. Run 'git push' first so the release reflects what's on GitHub, then re-run ./release.sh."
    exit 1
fi

# --- Safety: don't clobber an existing version ---
if git rev-parse "$TAG" >/dev/null 2>&1 || gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: $TAG already exists. Bump MARKETING_VERSION in ReSign.xcodeproj/project.pbxproj, commit, and push before releasing a new version."
    exit 1
fi

# --- Build fresh (Release, staged into ./build, no install) ---
echo "→ Building $APP_NAME $VERSION..."
./build.sh --no-install

APP_PATH="build/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH not found after build. Run './build.sh --no-install -v' to see full output."
    exit 1
fi

# --- Zip the artifact (ditto preserves the .app bundle + code signature) ---
ZIP="build/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
echo "→ Zipping $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP"

# --- Tag and publish ---
echo "→ Tagging $TAG and creating GitHub release"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" \
    --title "$APP_NAME $VERSION" \
    --generate-notes

echo "✓ Released $TAG with $ZIP attached."
