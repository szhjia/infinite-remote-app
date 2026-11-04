#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
bin="$build_dir/RemoteDesk"
app="dist/RemoteDesk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$build_dir/RemoteDesk_RemoteDesk.bundle" "$app/Contents/Resources/RemoteDesk_RemoteDesk.bundle"
install -m 755 "$bin" "$app/Contents/MacOS/RemoteDesk"
install -m 644 scripts/RemoteDesk.icns "$app/Contents/Resources/RemoteDesk.icns"
install -m 644 scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
printf "App: %s/%s\n" "$PWD" "$app"
