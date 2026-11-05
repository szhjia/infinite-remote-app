#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
signing_identity="${REMOTEDESK_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" && -f dist/.signing-identity ]]; then
    signing_identity=$(<dist/.signing-identity)
fi
signing_identity="${signing_identity:--}"
swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
bin="$build_dir/RemoteDesk"
app="dist/RemoteDesk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$build_dir/RemoteDesk_RemoteDesk.bundle" "$app/Contents/Resources/RemoteDesk_RemoteDesk.bundle"
install -m 755 "$bin" "$app/Contents/MacOS/RemoteDesk"
install -m 644 scripts/RemoteDesk.icns "$app/Contents/Resources/RemoteDesk.icns"
install -m 644 scripts/Info.plist "$app/Contents/Info.plist"
if [[ "$signing_identity" == "-" ]]; then
    printf '%s\n' 'Using ad hoc signing. Set REMOTEDESK_SIGNING_IDENTITY to keep macOS privacy permissions across rebuilds.' >&2
fi
codesign --force --sign "$signing_identity" "$app"
codesign --verify --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
printf "App: %s/%s\n" "$PWD" "$app"
