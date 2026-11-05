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
mkdir -p dist
stage=$(mktemp -d dist/.remotedesk-build.XXXXXX)
trap 'rm -rf "$stage"' EXIT
staged_app="$stage/RemoteDesk.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
ditto "$build_dir/RemoteDesk_RemoteDesk.bundle" "$staged_app/Contents/Resources/RemoteDesk_RemoteDesk.bundle"
install -m 755 "$bin" "$staged_app/Contents/MacOS/RemoteDesk"
install -m 644 scripts/RemoteDesk.icns "$staged_app/Contents/Resources/RemoteDesk.icns"
install -m 644 scripts/Info.plist "$staged_app/Contents/Info.plist"
if [[ "$signing_identity" == "-" ]]; then
    printf '%s\n' 'Using ad hoc signing. Set REMOTEDESK_SIGNING_IDENTITY to keep macOS privacy permissions across rebuilds.' >&2
fi
codesign --force --sign "$signing_identity" "$staged_app"
codesign --verify --strict "$staged_app"
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist"

# Keep the current bundle in place until the verified replacement is ready.
swift - "$staged_app" "$app" <<'SWIFT'
import Darwin

let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
if renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST,
          renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("Publishing RemoteDesk.app")
        exit(EXIT_FAILURE)
    }
}
SWIFT
printf "App: %s/%s\n" "$PWD" "$app"
