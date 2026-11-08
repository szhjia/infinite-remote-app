#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if (( $# > 2 )); then
    printf 'Usage: %s [app-path [output.dmg]]\n' "$0" >&2
    exit 2
fi

app="${1:-dist/Infinite Remote.app}"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf 'Invalid app version or build: %s (%s)\n' "$version" "$build" >&2
    exit 1
fi
architecture=$(lipo -archs "$app/Contents/MacOS/RemoteDesk")
if [[ "$architecture" == *" "* ]]; then architecture=universal; fi
output="${2:-dist/Infinite-Remote-v$version-build$build-macos-$architecture.dmg}"
if [[ "$output" != *.dmg || -e "$output" || -L "$output" ]]; then
    printf 'Expected a new .dmg output path: %s\n' "$output" >&2
    exit 1
fi

signing_identity="${REMOTEDESK_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" && -f dist/.signing-identity ]]; then
    signing_identity=$(<dist/.signing-identity)
fi
signing_identity="${signing_identity:--}"

codesign --verify --strict --deep "$app"
output_dir=$(dirname "$output")
mkdir -p "$output_dir"
stage=$(mktemp -d "$output_dir/.remotedesk-dmg.XXXXXX")
mountpoint="$stage/contents"
mounted=false
cleanup() {
    if $mounted && ! hdiutil detach "$mountpoint" >/dev/null; then
        return
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
mkdir "$mountpoint"

# The Finder background bookmark points into the template's filesystem.
# Convert the image in place so the background keeps its volume and file identity.
writable="$stage/installer-rw.dmg"
hdiutil convert scripts/dmg-assets/installer-template.dmg -format UDRW -o "$writable"
app_size=$(du -sm "$app" | cut -f 1)
hdiutil resize -size "$((app_size + 24))m" "$writable"
hdiutil attach -readwrite -nobrowse -noautoopen -mountpoint "$mountpoint" "$writable"
mounted=true
[[ -f "$mountpoint/.DS_Store" && -f "$mountpoint/.background.png" ]]
[[ "$(readlink "$mountpoint/Applications")" == /Applications ]]
[[ ! -e "$mountpoint/Infinite Remote.app" ]]
# Keep the original background pathname and file identity for Finder's bookmark.
cat scripts/dmg-assets/installation-arrow.gif > "$mountpoint/.background.png"
ditto "$app" "$mountpoint/Infinite Remote.app"
hdiutil detach "$mountpoint"
mounted=false

image="$stage/$(basename "$output")"
hdiutil convert "$writable" -format UDZO -o "$image"
codesign --sign "$signing_identity" "$image"
codesign --verify --verbose "$image"
hdiutil verify "$image"
mv -n "$image" "$output"
if [[ -e "$image" ]]; then
    printf 'Output path was created by another process: %s\n' "$output" >&2
    exit 1
fi
printf 'DMG: %s\n' "$output"
