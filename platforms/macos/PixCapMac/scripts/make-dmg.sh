#!/bin/bash
#
# Packages PixCap.app into a distributable disk image.
#
# Signs with a Developer ID when scripts/signing.env provides one, submits the
# image to Apple for notarisation, and staples the ticket so it opens cleanly
# on any Mac. Falls back to an ad-hoc signature when unconfigured.
#
# Usage:  ./scripts/make-dmg.sh [version]

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PACKAGE_DIR/build"
APP="$BUILD_DIR/PixCap.app"
VERSION="${1:-$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 2.0.0)}"
DMG="$BUILD_DIR/PixCap-$VERSION.dmg"
STAGING="$BUILD_DIR/dmg-staging"

if [ ! -d "$APP" ]; then
    echo "▸ PixCap.app not found — building it first…"
    "$PACKAGE_DIR/scripts/make-app.sh" release
fi

echo "▸ Staging disk image contents…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"

cp -R "$APP" "$STAGING/PixCap.app"
# Drag-to-install target.
ln -s /Applications "$STAGING/Applications"

# Volume icon, so the mounted disk uses the app mark rather than a blank drive.
if [ -f "$PACKAGE_DIR/Resources/AppIcon.icns" ]; then
    cp "$PACKAGE_DIR/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
fi

echo "▸ Building disk image…"
# Built read-write first so Finder can lay the window out, then compressed.
TEMP_DMG="$BUILD_DIR/PixCap-rw.dmg"
rm -f "$TEMP_DMG"
hdiutil create \
    -volname "PixCap $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    "$TEMP_DMG" >/dev/null

rm -rf "$STAGING"

echo "▸ Arranging the window…"
MOUNT_POINT="$(hdiutil attach "$TEMP_DMG" -nobrowse -noverify | grep -o '/Volumes/.*$' | tail -1)"

if [ -n "$MOUNT_POINT" ]; then
    # Finder scripting needs Automation permission; a refusal must not fail the
    # build, it just leaves the default icon arrangement.
    osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "  (Finder layout skipped — grant Automation access to run it)"
tell application "Finder"
    tell disk "PixCap $VERSION"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 780, 500}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 12
        set position of item "PixCap.app" of container window to {140, 170}
        set position of item "Applications" of container window to {420, 170}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

    # Tell Finder to use .VolumeIcon.icns for the mounted volume.
    if [ -f "$MOUNT_POINT/.VolumeIcon.icns" ]; then
        SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
    fi

    sync
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1
fi

echo "▸ Compressing…"
rm -f "$DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TEMP_DMG"

# ---------------------------------------------------------------------------
# Sign and notarise
# ---------------------------------------------------------------------------
# Values passed on the command line win over the config file, so a one-off
# `PIXCAP_NOTARIZE=0 ./scripts/make-dmg.sh` behaves as expected.
_env_identity="${PIXCAP_SIGN_IDENTITY:-}"
_env_profile="${PIXCAP_NOTARY_PROFILE:-}"
_env_notarize="${PIXCAP_NOTARIZE:-}"

[ -f "$PACKAGE_DIR/scripts/signing.env" ] && source "$PACKAGE_DIR/scripts/signing.env"

IDENTITY="${_env_identity:-${PIXCAP_SIGN_IDENTITY:-}}"
PROFILE="${_env_profile:-${PIXCAP_NOTARY_PROFILE:-PixCap}}"
NOTARIZE="${_env_notarize:-${PIXCAP_NOTARIZE:-1}}"

if [ -n "$IDENTITY" ]; then
    echo "▸ Signing disk image…"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"

    if [ "$NOTARIZE" = "1" ]; then
        echo "▸ Submitting to Apple for notarisation (this usually takes 1–5 minutes)…"
        if xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
            # Stapling attaches the ticket so the image validates offline.
            echo "▸ Stapling ticket…"
            xcrun stapler staple "$DMG"
            xcrun stapler validate "$DMG"

            # Staple the standalone bundle too. Notarising the image covers the
            # app inside it, and Apple serves the ticket by content hash, so the
            # loose build/PixCap.app also validates without a network check.
            xcrun stapler staple "$APP" >/dev/null 2>&1 && echo "  stapled PixCap.app as well"

            NOTARISED=1
        else
            echo
            echo "⚠️  Notarisation failed. The image is signed but will still be"
            echo "   blocked on other Macs. Common causes:"
            echo "     • the keychain profile '$PROFILE' does not exist yet —"
            echo "       run: xcrun notarytool store-credentials \"$PROFILE\" \\"
            echo "              --apple-id <apple-id> --team-id ${PIXCAP_TEAM_ID:-<team-id>} \\"
            echo "              --password <app-specific-password>"
            echo "     • the app was not signed with the hardened runtime"
            echo "   Inspect the last submission with:"
            echo "     xcrun notarytool log <submission-id> --keychain-profile \"$PROFILE\""
            NOTARISED=0
        fi
    fi
fi

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"

echo
echo "✅ Built $DMG  ($SIZE)"
echo

if [ -n "$IDENTITY" ] && [ "${NOTARISED:-0}" = "1" ]; then
    echo "Signed with Developer ID and notarised — this opens cleanly on any Mac."
elif [ -n "$IDENTITY" ]; then
    echo "Signed with Developer ID but NOT notarised: macOS will still warn on"
    echo "first launch on another Mac."
else
    echo "Ad-hoc signed: Gatekeeper will block this on any Mac but this one."
    echo "Add scripts/signing.env (see signing.env.example) to sign properly."
fi
