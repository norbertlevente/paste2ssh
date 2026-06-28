#!/usr/bin/env bash
# Build a notarized release and (re)generate the Sparkle appcast.
#
# Prereqs: a Developer ID Application cert + a notarytool keychain profile
# (export P2SS_NOTARY_PROFILE, default "P2SS_NOTARY"), and the Sparkle EdDSA
# private key in the login Keychain (created once via Sparkle's generate_keys).
#
# Output (in dist/): Paste2SSH-<version>.dmg + appcast.xml. Publish BOTH to the
# site repo (served from https://paste2ssh.com/), bump the download links, and push.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Paste2SSH"
DIST_DIR="$ROOT_DIR/dist"
DOWNLOAD_PREFIX="https://paste2ssh.com/"
GEN_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Resources/Info.plist")"

export P2SS_NOTARY_PROFILE="${P2SS_NOTARY_PROFILE:-P2SS_NOTARY}"
echo "== Building notarized $APP_NAME $VERSION (build $BUILD) =="
"$ROOT_DIR/build.sh"

mkdir -p "$DIST_DIR"
cp "$ROOT_DIR/$APP_NAME.dmg" "$DIST_DIR/$APP_NAME-$VERSION.dmg"

if [ ! -x "$GEN_APPCAST" ]; then
  echo "ERROR: generate_appcast not found at $GEN_APPCAST (run 'swift build' first)" >&2
  exit 1
fi

echo "== Generating appcast over $DIST_DIR =="
# Per-version release notes: author dist/Paste2SSH-<version>.html as a small HTML
# snippet (no DOCTYPE/body tags) with just that version's notes; generate_appcast
# embeds it inline as the update's <description>. A "Full Release Notes" link points
# at the changelog. This keeps the in-app update prompt concise (no site chrome).
"$GEN_APPCAST" --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --full-release-notes-url "https://paste2ssh.com/changelog/" \
  "$DIST_DIR"

echo
echo "Done. Publish to the site repo (paste2ssh.com) and push:"
echo "  $DIST_DIR/appcast.xml"
echo "  $DIST_DIR/$APP_NAME-$VERSION.dmg"
