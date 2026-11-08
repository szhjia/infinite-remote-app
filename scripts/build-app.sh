#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
signing_identity="${REMOTEDESK_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" && -f dist/.signing-identity ]]; then
    signing_identity=$(<dist/.signing-identity)
fi
signing_identity="${signing_identity:--}"
swift build -c release -Xlinker -rpath -Xlinker '@loader_path/../Frameworks'
build_dir="$(swift build -c release --show-bin-path)"
bin="$build_dir/RemoteDesk"
app="dist/Infinite Remote.app"
mkdir -p dist
stage=$(mktemp -d dist/.remotedesk-build.XXXXXX)
trap 'rm -rf "$stage"' EXIT
staged_app="$stage/Infinite Remote.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/Frameworks"
ditto "$build_dir/Infinite Remote_RemoteDesk.bundle" "$staged_app/Contents/Resources/Infinite Remote_RemoteDesk.bundle"
# Incremental SwiftPM outputs can retain removed resources. Never ship legacy models.
rm -rf "$staged_app/Contents/Resources/Infinite Remote_RemoteDesk.bundle/RemoteModels"
install -m 755 "$bin" "$staged_app/Contents/MacOS/RemoteDesk"
install -m 644 scripts/RemoteDesk.icns "$staged_app/Contents/Resources/RemoteDesk.icns"
install -m 644 scripts/Info.plist "$staged_app/Contents/Info.plist"
install -m 644 LICENSE "$staged_app/Contents/Resources/LICENSE.txt"
install -m 644 scripts/LICENSE-Sparkle.txt "$staged_app/Contents/Resources/LICENSE-Sparkle.txt"
sparkle="$staged_app/Contents/Frameworks/Sparkle.framework"
ditto "$build_dir/Sparkle.framework" "$sparkle"
for locale in en zh-Hans; do
    mkdir -p "$staged_app/Contents/Resources/$locale.lproj"
    install -m 644 "Sources/RemoteDesk/Resources/Localization/$locale.lproj/InfoPlist.strings" "$staged_app/Contents/Resources/$locale.lproj/InfoPlist.strings"
done
signing_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" == "-" ]]; then
    printf '%s\n' 'Using ad hoc signing. Set REMOTEDESK_SIGNING_IDENTITY to keep macOS privacy permissions across rebuilds.' >&2
elif [[ "$signing_identity" == 'Developer ID Application:'* ]]; then
    signing_options+=(--options runtime --timestamp)
fi
sparkle_version="$sparkle/Versions/Current"
for component in "$sparkle_version"/XPCServices/*.xpc "$sparkle_version/Autoupdate" "$sparkle_version/Updater.app"; do
    codesign "${signing_options[@]}" --preserve-metadata=entitlements "$component"
done
codesign "${signing_options[@]}" "$sparkle"
codesign "${signing_options[@]}" "$staged_app"
codesign --verify --deep --strict "$staged_app"
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist"

# Keep the current bundle in place until the verified replacement is ready.
swift - "$staged_app" "$app" <<'SWIFT'
import Darwin

let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
if renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST,
          renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("Publishing Infinite Remote.app")
        exit(EXIT_FAILURE)
    }
}
SWIFT
printf "App: %s/%s\n" "$PWD" "$app"
