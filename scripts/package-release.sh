#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
app="dist/Infinite Remote.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid release version: %s\n' "$version" >&2; exit 1; }
architecture=$(lipo -archs "$app/Contents/MacOS/RemoteDesk")
if [[ "$architecture" == *" "* ]]; then architecture=universal; fi
archive="Infinite-Remote-v${version}-macos-${architecture}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$archive"
(
    cd dist
    shasum -a 256 "$archive" > "$archive.sha256"
)
printf 'Release: %s/dist/%s\n' "$PWD" "$archive"
