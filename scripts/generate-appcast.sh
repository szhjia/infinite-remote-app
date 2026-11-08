#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -f "$1" || ( $# -eq 2 && ! -f "$2" ) ]]; then
    printf 'Usage: SPARKLE_BIN_DIR=/absolute/path/to/bin %s FINAL.dmg [release-notes.md]\n' "$0" >&2
    exit 1
fi

dmg="$1"
asset="${dmg##*/}"
if [[ ! "$asset" =~ ^Infinite-Remote-v([0-9]+\.[0-9]+\.[0-9]+)-build([0-9]+(\.[0-9]+){0,2})-macos-(arm64|universal)\.dmg$ ]]; then
    printf 'Unexpected release asset name: %s\n' "$asset" >&2
    exit 1
fi
version="${BASH_REMATCH[1]}"
build="${BASH_REMATCH[2]}"
expected_hardware=
if [[ "${BASH_REMATCH[4]}" == arm64 ]]; then
    expected_hardware=arm64
fi

sparkle_bin="${SPARKLE_BIN_DIR:?Set SPARKLE_BIN_DIR to the bin directory of the pinned Sparkle distribution}"
account=infinite-remote
app_root="$(cd "$(dirname "$0")/.." && pwd)"
public_key=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app_root/scripts/Info.plist")
if [[ "$("$sparkle_bin/generate_keys" --account "$account" -p)" != "$public_key" ]]; then
    printf 'The Sparkle Keychain account %s must match the app public key.\n' "$account" >&2
    exit 1
fi

codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$dmg"
xcrun stapler validate "$dmg"
mkdir -p "$app_root/dist"
stage=$(mktemp -d "$app_root/dist/.appcast.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp "$dmg" "$stage/$asset"
if [[ $# -eq 2 ]]; then
    cp "$2" "$stage/${asset%.dmg}.md"
fi

release_url="https://github.com/szhjia/infinite-remote-app/releases"
download_prefix="$release_url/download/v$version/"
"$sparkle_bin/generate_appcast" --account "$account" --maximum-deltas 0 --embed-release-notes \
    --link "$release_url/tag/v$version" --download-url-prefix "$download_prefix" "$stage"
feed="$stage/appcast.xml"
"$sparkle_bin/sign_update" --account "$account" --verify "$feed"

item='/rss/channel/item'
field() {
    xmllint --xpath "string($item/$1)" "$feed"
}
sparkle="namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle'"
if [[ "$(xmllint --xpath "count($item)" "$feed")" != 1 ||
      "$(field "*[local-name()='version' and $sparkle]")" != "$build" ||
      "$(field "*[local-name()='shortVersionString' and $sparkle]")" != "$version" ||
      "$(field 'enclosure/@url')" != "$download_prefix$asset" ||
      "$(field 'enclosure/@length')" != "$(stat -f %z "$dmg")" ||
      -z "$(field "enclosure/@*[local-name()='edSignature' and $sparkle]")" ||
      "$(field "*[local-name()='hardwareRequirements' and $sparkle]")" != "$expected_hardware" ]]; then
    printf 'The generated feed does not match the release DMG.\n' >&2
    exit 1
fi

mv -f "$feed" "$app_root/dist/appcast.xml"
printf 'Appcast: %s/dist/appcast.xml\n' "$app_root"
