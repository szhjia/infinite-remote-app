#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd -P)
script="$repo/scripts/notarize-release.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/notarize-release-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export TEST_CALLS="$test_dir/calls"
export TEST_ID=426c2ffd-bf19-4658-b36f-bbdba23ebb1c
export PATH="$test_dir:$PATH"
export NOTARY_KEYCHAIN_PROFILE=test-profile

cat > "$test_dir/xcrun" <<'STUB'
#!/bin/bash
set -eu
[[ "$1" == notarytool ]]
shift
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$1" in
    submit)
        [[ " $* " == *' --no-wait '* && " $* " == *' --keychain-profile test-profile '* ]]
        case "$TEST_MODE" in
            id_only)
                printf '{"id":"%s","status":"In Progress"}\n' "$TEST_ID"
                exit 0 ;;
            auth_error)
                printf 'Error: HTTP status code: 401\n' >&2
                exit 1 ;;
            timed_out|both_timed_out)
                if [[ "$TEST_MODE" == both_timed_out || " $* " != *' --no-s3-acceleration '* ]]; then
                    printf '{"id":"%s","status":"In Progress"}\n' "$TEST_ID"
                    printf 'Error: HTTPClientError.deadlineExceeded\n' >&2
                    exit 1
                fi ;;
        esac
        printf '{"message":"Successfully uploaded file","id":"%s"}\n' "$TEST_ID"
        [[ "$TEST_MODE" != failed_exit ]] ;;
    wait)
        [[ "$2" == "$TEST_ID" && " $* " == *' --keychain-profile test-profile '* ]]
        if [[ "$TEST_MODE" == review_timeout ]]; then
            printf '{"message":"Timeout before processing completed.","id":"%s"}\n' "$TEST_ID"
            exit 124
        fi
        status=Accepted
        if [[ "$TEST_MODE" == rejected ]]; then status=Invalid; fi
        printf '{"message":"Processing complete","id":"%s","status":"%s"}\n' "$TEST_ID" "$status" ;;
esac
STUB
chmod +x "$test_dir/xcrun"

scenario() {
    export TEST_MODE=$1
    archive="$test_dir/$1 candidate.dmg"
    printf 'original bytes\n' > "$archive"
    : > "$TEST_CALLS"
}

run() { bash "$script" "$@" > "$test_dir/stdout" 2> "$test_dir/stderr"; }

expect_failure() {
    if run "$@"; then
        printf 'Unexpected success in %s for %s\n' "$TEST_MODE" "$1" >&2
        exit 1
    fi
}

scenario success
run submit "$archive"
grep -Fq "Upload confirmed. Submission ID: $TEST_ID" "$test_dir/stdout"
[[ -f "$archive.notary/submission.json" ]]
run submit "$archive"
grep -Fq 'Upload already confirmed.' "$test_dir/stdout"
[[ $(grep -c '^submit ' "$TEST_CALLS") == 1 ]]
NOTARY_KEYCHAIN_PROFILE=other-profile run wait "$archive" 5s
grep -Fq -- ' --timeout 5s ' "$TEST_CALLS"
grep -Fq '"status":"Accepted"' "$test_dir/stdout"

scenario timed_out
run submit "$archive"
[[ $(grep -c '^submit ' "$TEST_CALLS") == 2 ]]
[[ $(grep -c -- ' --no-s3-acceleration$' "$TEST_CALLS") == 1 ]]
[[ -s "$archive.notary/default.stderr" && -f "$archive.notary/submission.json" ]]
export TEST_MODE=review_timeout
expect_failure wait "$archive" 5s
grep -Fq "Run wait again for the same archive and submission $TEST_ID" "$test_dir/stderr"
export TEST_MODE=rejected
expect_failure wait "$archive" 5s
grep -Fq 'Apple returned Invalid' "$test_dir/stderr"
export TEST_MODE=success
run wait "$archive"
[[ $(grep -c '^submit ' "$TEST_CALLS") == 2 ]]
[[ $(grep -c "^wait $TEST_ID " "$TEST_CALLS") == 3 ]]
printf 'changed bytes\n' >> "$archive"
expect_failure wait "$archive"
grep -Fq 'SHA-256 differs' "$test_dir/stderr"
[[ $(grep -c '^wait ' "$TEST_CALLS") == 3 ]]

for mode in id_only auth_error failed_exit both_timed_out; do
    scenario "$mode"
    expect_failure submit "$archive"
    [[ ! -e "$archive.notary/submission.json" ]]
    expect_failure submit "$archive"
    expect_failure wait "$archive"
    if [[ "$mode" == both_timed_out ]]; then
        [[ $(wc -l < "$TEST_CALLS") -eq 2 ]]
    else
        [[ $(wc -l < "$TEST_CALLS") -eq 1 ]]
    fi
done

printf 'Notarization workflow checks passed.\n'
