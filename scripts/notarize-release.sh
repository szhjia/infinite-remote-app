#!/bin/bash
set -euo pipefail
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }

usage='Usage: bash scripts/notarize-release.sh submit <DMG-or-ZIP>
       bash scripts/notarize-release.sh wait <DMG-or-ZIP> [timeout]'
case "${1:-}" in
    submit) [[ $# == 2 ]] || die "$usage" ;;
    wait) [[ $# == 2 || $# == 3 ]] || die "$usage" ;;
    *) die "$usage" ;;
esac
[[ -f "$2" ]] || die "Archive not found: $2"
archive="$(cd "$(dirname -- "$2")" && pwd -P)/$(basename -- "$2")"
state="$archive.notary"
receipt="$state/submission.json"
digest=$(shasum -a 256 < "$archive")
digest=${digest%% *}

json_string() {
    /usr/bin/plutil -extract "$1" raw -expect string -o - "$2" 2>/dev/null
}

confirmed_id() {
    local message id
    message=$(json_string message "$1") && [[ "$message" == 'Successfully uploaded file' ]] || return 1
    id=$(json_string id "$1") || return 1
    [[ "$id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || return 1
    printf '%s\n' "$id"
}

read_submission() {
    id=$(confirmed_id "$receipt") || die "No confirmed upload receipt at $receipt. Inspect $state before submitting again."
    [[ $(<"$state/archive.sha256") == "$digest" ]] || die 'Archive SHA-256 differs from the uploaded file.'
    profile=$(<"$state/keychain-profile")
    [[ -n "$profile" ]] || die 'The original Keychain profile is missing.'
}

upload() {
    local endpoint=$1
    shift
    xcrun notarytool submit "$archive" --keychain-profile "$profile" --no-wait --output-format json "$@" \
        > "$state/$endpoint.json" 2> "$state/$endpoint.stderr"
}

if [[ "$1" == submit ]]; then
    if [[ -f "$receipt" ]]; then
        read_submission
        printf 'Upload already confirmed. Submission ID: %s\n' "$id"
        exit 0
    fi

    # Claim this archive before uploading so concurrent calls cannot submit it twice.
    mkdir "$state" || die "Notarization state already exists at $state. Inspect it before submitting again."
    profile=${NOTARY_KEYCHAIN_PROFILE:-infinite-remote-notary}
    printf '%s\n' "$profile" > "$state/keychain-profile"
    printf '%s\n' "$digest" > "$state/archive.sha256"

    endpoint=default
    if ! upload "$endpoint"; then
        grep -Eiq 'deadlineExceeded|timed out|ETIMEDOUT|NSURLErrorDomain.*-1001|HTTP status code: (408|504)' "$state/default.stderr" \
            || die "Upload failed. See $state/default.stderr."
        printf 'Upload timed out. Retrying once via the regional endpoint.\n' >&2
        endpoint=regional
        upload "$endpoint" --no-s3-acceleration || die "Regional upload failed. See $state/regional.stderr."
    fi

    id=$(confirmed_id "$state/$endpoint.json") \
        || die "Upload not confirmed. See $state/$endpoint.json and $state/$endpoint.stderr."
    mv "$state/$endpoint.json" "$receipt"
    printf 'Upload confirmed. Submission ID: %s\nReceipt: %s\n' "$id" "$receipt"
    exit 0
fi

read_submission
timeout=${3:-15m}
review=$(xcrun notarytool wait "$id" --keychain-profile "$profile" --timeout "$timeout" --output-format json) || {
    printf '%s\n' "$review" >&2
    die "Review did not complete. Run wait again for the same archive and submission $id."
}
printf '%s\n' "$review"
status=$(printf '%s\n' "$review" | json_string status -) || die "Could not read the review status for $id."
[[ "$status" == Accepted ]] || die "Apple returned $status for $id. Retrieve the log with xcrun notarytool log."
