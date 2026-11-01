#!/bin/zsh
# Builds "WB7022 Control.app" next to this script.
#
#   ./bundle.sh               this Mac's architecture
#   ./bundle.sh --universal   Apple silicon and Intel in one binary
#
# VERSION (e.g. 1.2) and BUILD (e.g. 7) override the bundle's version strings.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--universal" ]]; then
    # One build per architecture, each in its own folder (newer SwiftPM shares
    # one output folder across architectures), joined with lipo.
    BIN=".build/WB7022Control-universal"
    for arch in arm64 x86_64; do swift build -c release --arch "$arch" --scratch-path ".build/$arch"; done
    lipo -create -output "$BIN" \
        "$(swift build -c release --arch arm64 --scratch-path .build/arm64 --show-bin-path)/WB7022Control" \
        "$(swift build -c release --arch x86_64 --scratch-path .build/x86_64 --show-bin-path)/WB7022Control"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/WB7022Control"
fi
APP="WB7022 Control.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WB7022Control"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi
codesign --force --sign - --identifier local.wb7022control "$APP"
echo "Built $PWD/$APP"
