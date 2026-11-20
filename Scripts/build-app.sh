#!/bin/bash
# Builds build/ZipShot.app from the Swift package.
#
#   Scripts/build-app.sh            build the app
#   Scripts/build-app.sh --run      build, then launch it
#   Scripts/build-app.sh --install  build, copy to /Applications, launch that copy
#
# Signing: ad-hoc by default. macOS ties the Screen Recording permission to the
# signature, and an ad-hoc signature changes with every build, so each rebuild
# asks for the permission again. To keep it across rebuilds, sign with a stable
# identity (a self-signed "Code Signing" certificate from Keychain Access works):
#
#   ZIPSHOT_SIGN_IDENTITY="My Certificate Name" Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ZipShot.app
IDENTITY="${ZIPSHOT_SIGN_IDENTITY:--}"

swift build -c release --product ZipShot
BIN="$(swift build -c release --show-bin-path)/ZipShot"

mkdir -p build
if [ ! -f build/AppIcon.icns ] || [ Scripts/make-icon.swift -nt build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    swift Scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ZipShot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP"

case "${1:-}" in
    --run)
        open "$APP"
        ;;
    --install)
        # Quit a running copy first so the new one can take its place.
        pkill -x ZipShot >/dev/null 2>&1 || true
        rm -rf /Applications/ZipShot.app
        cp -R "$APP" /Applications/ZipShot.app
        echo "Installed /Applications/ZipShot.app"
        open /Applications/ZipShot.app
        ;;
    "")
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
esac
