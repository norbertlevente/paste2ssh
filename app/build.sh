#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Paste2SSH"
BUNDLE_ID="com.paste2ssh.app"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
DMG_STAGE="$ROOT_DIR/dmg-stage"
DMG_PATH="$ROOT_DIR/$APP_NAME.dmg"
ENTITLEMENTS="$ROOT_DIR/Paste2SSH.entitlements"

# --- Signing identity ---------------------------------------------------------
# Default is ad-hoc ("-") for local/private builds.
# For a notarizable release, either:
#   export P2SS_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
# or just install a Developer ID Application cert; this script auto-detects it.
SIGN_IDENTITY="${P2SS_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  # `|| true` so an absent Developer ID cert isn't fatal under `set -e`/pipefail.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | awk '{print $2}' || true)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi

# --- Notarization (optional) --------------------------------------------------
# One-time setup:
#   xcrun notarytool store-credentials P2SS_NOTARY \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
# Then: export P2SS_NOTARY_PROFILE=P2SS_NOTARY
NOTARY_PROFILE="${P2SS_NOTARY_PROFILE:-}"

cd "$ROOT_DIR"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP_DIR" "$DMG_STAGE" "$DMG_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Resources/MenuBarIcon.png" "$APP_DIR/Contents/Resources/MenuBarIcon.png"

# Embed Sparkle.framework (auto-update) from the SwiftPM build products.
if [ ! -d "$BIN_DIR/Sparkle.framework" ]; then
  echo "ERROR: Sparkle.framework not found in $BIN_DIR" >&2
  exit 1
fi
mkdir -p "$APP_DIR/Contents/Frameworks"
cp -R "$BIN_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

# --- Codesign -----------------------------------------------------------------
# Hardened runtime is required for notarization. Sparkle's framework + helpers are
# re-signed inner-out (below) with our identity so they're same-team for library
# validation, before the app bundle is signed last (no --deep). A secure timestamp
# is added for real (non-ad-hoc) identities.
CODESIGN_FLAGS=(--force --options runtime
                --entitlements "$ENTITLEMENTS"
                --identifier "$BUNDLE_ID")
if [ "$SIGN_IDENTITY" != "-" ]; then
  CODESIGN_FLAGS+=(--timestamp)
  echo "Signing with: $SIGN_IDENTITY"
else
  echo "Signing ad-hoc (set P2SS_SIGN_IDENTITY for a notarizable release)"
fi

# Sign Sparkle inner-out: each nested executable keeps its own bundle id and gets
# hardened runtime, but not the app's entitlements/identifier.
SPARKLE_FW="$APP_DIR/Contents/Frameworks/Sparkle.framework"
SPARKLE_V="$SPARKLE_FW/Versions/B"
SPARKLE_FLAGS=(--force --options runtime)
if [ "$SIGN_IDENTITY" != "-" ]; then
  SPARKLE_FLAGS+=(--timestamp)
fi
for COMPONENT in \
  "$SPARKLE_V/XPCServices/Installer.xpc" \
  "$SPARKLE_V/XPCServices/Downloader.xpc" \
  "$SPARKLE_V/Updater.app" \
  "$SPARKLE_V/Autoupdate" \
  "$SPARKLE_FW"; do
  /usr/bin/codesign "${SPARKLE_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$COMPONENT"
done

/usr/bin/codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# --- Notarize + staple the app ------------------------------------------------
if [ "$SIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing app..."
  APP_ZIP="$ROOT_DIR/$APP_NAME-app.zip"
  rm -f "$APP_ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  rm -f "$APP_ZIP"
  echo "Stapled app."
fi

# --- Build the DMG from the (possibly stapled) app ----------------------------
mkdir -p "$DMG_STAGE"
cp -R "$APP_DIR" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov "$DMG_PATH"

# Sign the DMG container itself so Gatekeeper trusts the download, not just the
# app inside (notarization alone leaves the DMG with "no usable signature").
if [ "$SIGN_IDENTITY" != "-" ]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"
fi

# --- Notarize + staple the DMG so the download is trusted offline -------------
if [ "$SIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing DMG..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  echo "Stapled DMG."
  echo "Gatekeeper assessment:"
  spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH" || true
fi

echo "Built $APP_DIR"
echo "Built $DMG_PATH"
