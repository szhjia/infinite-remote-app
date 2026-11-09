#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$(pwd -P)

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# == 1 && "${1:-}" =~ ^[0-9a-f]{40}$ ]] || die 'Usage: bash scripts/package-public-dmg.sh <full release commit SHA>'
expected=$1
remote=https://github.com/szhjia/infinite-remote-app.git
ref=refs/heads/main

check_source() {
    local status head upstream
    status=$(git status --porcelain=v1 --untracked-files=all --ignore-submodules=none)
    [[ -z "$status" ]] || die "Commit the intended release changes and start from a clean worktree:
$status"
    head=$(git rev-parse --verify HEAD)
    [[ "$head" == "$expected" ]] || die "Local HEAD ($head) does not match the reviewed release commit ($expected)."
    upstream=$(git ls-remote --exit-code "$remote" "$ref") || die 'Could not verify the current GitHub main commit.'
    upstream=${upstream%%$'\t'*}
    [[ "$upstream" == "$expected" ]] || die "GitHub main ($upstream) does not match the reviewed release commit ($expected)."
}
check_source
[[ "${REMOTEDESK_SIGNING_IDENTITY:-}" == 'Developer ID Application:'* ]] || die 'Set REMOTEDESK_SIGNING_IDENTITY to the release Developer ID Application identity.'

# Export only tracked files from the verified commit. Neither an old dist bundle
# nor an ignored build product in the calling worktree can enter this build.
stage=$(mktemp -d "${TMPDIR:-/tmp}/infinite-remote-public.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/source" "$stage/modules"
git archive --format=tar "$expected" | tar -xf - -C "$stage/source"
(
    cd "$stage/source"
    export CLANG_MODULE_CACHE_PATH="$stage/modules"
    export SWIFTPM_MODULECACHE_OVERRIDE="$stage/modules"
    export REMOTEDESK_SOURCE_COMMIT="$expected"
    bash Tests/ReleaseScripts/notarize-release-test.sh
    swift test --force-resolved-versions
    bash scripts/build-app.sh
    app='dist/Infinite Remote.app'
    plist="$app/Contents/Info.plist"
    [[ "$(/usr/bin/plutil -extract InfiniteRemoteSourceCommit raw "$plist")" == "$expected" ]]
    for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
        [[ "$(/usr/bin/plutil -extract "$key" raw "$plist")" == "$(/usr/bin/plutil -extract "$key" raw scripts/Info.plist)" ]]
    done
    bash scripts/package-dmg.sh "$app"
)
check_source

shopt -s nullglob
images=("$stage/source/dist/"*.dmg)
[[ ${#images[@]} == 1 ]] || die 'Expected exactly one freshly packaged DMG.'
mkdir -p dist
output=$(mktemp -d "$repo/dist/public-${expected:0:12}.XXXXXX")
mv -- "${images[0]}" "$output/"
printf 'Source commit: %s\nCandidate DMG (before notarization): %s/%s\n' "$expected" "$output" "$(basename "${images[0]}")"
