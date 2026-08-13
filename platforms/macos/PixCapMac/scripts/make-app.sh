#!/bin/bash
#
# Builds PixCap.app — a real application bundle.
#
# Running the bare SwiftPM binary works for the self-test, but not for real use:
# macOS ties Screen Recording permission, notifications, and launch-at-login to
# a bundle identifier, which a loose executable does not have. Without a bundle
# the TCC prompt is attributed to your terminal instead of PixCap.
#
# Usage:  ./scripts/make-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-release}"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$PACKAGE_DIR/../../.." && pwd)"
APP_DIR="$PACKAGE_DIR/build/PixCap.app"

echo "▸ Building Rust core ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
    (cd "$REPO_ROOT" && cargo build --release)
    RUST_DIR="$REPO_ROOT/target/release"
else
    (cd "$REPO_ROOT" && cargo build)
    RUST_DIR="$REPO_ROOT/target/debug"
fi

echo "▸ Building Swift app ($CONFIG)…"
(cd "$PACKAGE_DIR" && swift build -c "$CONFIG" -Xlinker -L"$RUST_DIR")
BINARY="$(cd "$PACKAGE_DIR" && swift build -c "$CONFIG" --show-bin-path)/PixCapMac"

echo "▸ Assembling bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

cp "$BINARY" "$APP_DIR/Contents/MacOS/PixCap"

# The Swift binary links the Rust core dynamically, by absolute path into the
# build tree. Embed the dylib and repoint the load command so the bundle is
# self-contained and can be moved to /Applications.
DYLIB_SOURCE="$(otool -L "$APP_DIR/Contents/MacOS/PixCap" | awk '/libpixcap_ffi\.dylib/ {print $1; exit}')"
if [ -n "$DYLIB_SOURCE" ] && [ -f "$DYLIB_SOURCE" ]; then
    cp "$DYLIB_SOURCE" "$APP_DIR/Contents/Frameworks/libpixcap_ffi.dylib"
    install_name_tool -change \
        "$DYLIB_SOURCE" \
        "@executable_path/../Frameworks/libpixcap_ffi.dylib" \
        "$APP_DIR/Contents/MacOS/PixCap"
    install_name_tool -id \
        "@executable_path/../Frameworks/libpixcap_ffi.dylib" \
        "$APP_DIR/Contents/Frameworks/libpixcap_ffi.dylib"
    echo "  embedded $(basename "$DYLIB_SOURCE")"
else
    echo "  note: no Rust dylib load command found (statically linked)"
fi

# App icon. Regenerated only when missing so rebuilds stay fast.
ICON="$PACKAGE_DIR/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
    echo "▸ Generating app icon…"
    mkdir -p "$PACKAGE_DIR/Resources"
    swift "$PACKAGE_DIR/scripts/make-icon.swift" "$ICON" >/dev/null
fi
cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PixCap</string>
    <key>CFBundleDisplayName</key>
    <string>PixCap</string>
    <key>CFBundleExecutable</key>
    <string>PixCap</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.pixcap.mac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Menu bar app: no Dock icon, no main window. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>PixCap</string>
</dict>
PLIST
echo "</plist>" >> "$APP_DIR/Contents/Info.plist"

# Signing. TCC keys permissions off the signature: a Developer ID signature is
# stable across rebuilds, so Screen Recording permission survives. An ad-hoc
# signature changes every build and has to be re-granted each time.
_env_identity="${PIXCAP_SIGN_IDENTITY:-}"
[ -f "$PACKAGE_DIR/scripts/signing.env" ] && source "$PACKAGE_DIR/scripts/signing.env"
IDENTITY="${_env_identity:-${PIXCAP_SIGN_IDENTITY:-}}"
ENTITLEMENTS="$PACKAGE_DIR/scripts/PixCap.entitlements"

if [ -n "$IDENTITY" ]; then
    echo "▸ Signing with Developer ID…"
    # Nested code first: signing the bundle seals whatever the frameworks
    # directory contains at that moment. (--deep is deprecated and unreliable.)
    if [ -f "$APP_DIR/Contents/Frameworks/libpixcap_ffi.dylib" ]; then
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" "$APP_DIR/Contents/Frameworks/libpixcap_ffi.dylib"
    fi

    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP_DIR"

    echo "▸ Verifying signature…"
    codesign --verify --strict --verbose=2 "$APP_DIR"
else
    echo "▸ Signing (ad-hoc — no PIXCAP_SIGN_IDENTITY set)…"
    codesign --force --sign - "$APP_DIR/Contents/Frameworks/libpixcap_ffi.dylib" 2>/dev/null || true
    codesign --force --sign - "$APP_DIR" 2>/dev/null
fi

echo
echo "✅ Built $APP_DIR"
echo
echo "Run it:      open \"$APP_DIR\""
echo "Look for the camera icon in your menu bar (there is no Dock icon)."
echo
echo "First launch will ask for Screen Recording permission. macOS applies that"
echo "permission at launch, so quit and reopen PixCap after granting it."
echo

if [ -n "$IDENTITY" ]; then
    echo "Signed with Developer ID — the signature is stable, so Screen Recording"
    echo "permission survives rebuilds."
else
    echo "Ad-hoc signed. The signature changes on every build, so if captures come"
    echo "out black, remove PixCap from System Settings › Privacy & Security ›"
    echo "Screen Recording and re-add it."
fi
