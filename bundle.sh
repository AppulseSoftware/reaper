#!/bin/zsh
# Build Reaper.app (menu bar only).
#   ./bundle.sh              ad-hoc signed build for this machine
#   ./bundle.sh --install    same, then copy to /Applications and launch
#   ./bundle.sh --release    universal, Developer ID signed (hardened runtime) and zipped
#                            SIGN_IDENTITY overrides the identity; NOTARY_PROFILE also notarizes
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0.1.0
MODE="${1:-}"
APP=build/Reaper.app

if [[ "$MODE" == "--release" ]]; then
    BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
else
    BUILD_FLAGS=(-c release)
fi
swift build "${BUILD_FLAGS[@]}"
BINARY="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/Reaper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Reaper"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Reaper</string>
    <key>CFBundleDisplayName</key><string>Reaper</string>
    <key>CFBundleIdentifier</key><string>nl.appulse.reaper</string>
    <key>CFBundleExecutable</key><string>Reaper</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright 2026 Appulse Software B.V. Apache License 2.0.</string>
</dict>
</plist>
PLIST

if [[ "$MODE" == "--release" ]]; then
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
    if [[ -z "$IDENTITY" ]]; then
        echo "No Developer ID Application identity found; set SIGN_IDENTITY" >&2
        exit 1
    fi
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Signed with: $IDENTITY"

    ZIP="build/Reaper-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Notarized and stapled"
    else
        echo "Not notarized (set NOTARY_PROFILE to notarize)"
    fi
    echo "Built $ZIP"
    exit 0
fi

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "$MODE" == "--install" ]]; then
    # Paths are case-insensitive: never clobber Cockos REAPER (or anything that isn't us).
    if [[ -d /Applications/Reaper.app ]]; then
        existing=$(defaults read /Applications/Reaper.app/Contents/Info CFBundleIdentifier 2>/dev/null || true)
        if [[ "$existing" != "nl.appulse.reaper" ]]; then
            echo "Refusing to replace /Applications/Reaper.app (bundle id: ${existing:-unknown})" >&2
            exit 1
        fi
    fi
    pkill -x Reaper || true
    rm -rf /Applications/Reaper.app
    cp -R "$APP" /Applications/
    open /Applications/Reaper.app
    echo "Installed to /Applications/Reaper.app"
fi
