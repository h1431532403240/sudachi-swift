#!/usr/bin/env bash
#
# fetch-test-dictionary.sh — write one SudachiDict system dictionary to DEST,
# downloading its zip only when CACHE_DIR doesn't hold it yet.
#
# Usage:
#   ./scripts/fetch-test-dictionary.sh VERSION TYPE FORMAT SHA256 CACHE_DIR DEST
#
#   VERSION    SudachiDict release, e.g. 20260723
#   TYPE       small, core or full
#   FORMAT     v1 (the format sudachi.rs 0.7+ reads) or v0 (legacy)
#   SHA256     sha256 of sudachi-dictionary-VERSION-TYPE.zip in that format
#   CACHE_DIR  keeps the zip between runs (CI saves and restores it with
#              actions/cache); the zip goes to CACHE_DIR/FORMAT/, because the
#              v0 and v1 zips of a release have the same file name. The CI
#              cache keys include this script's hash, so a change here
#              starts new cache entries.
#   DEST       where system_TYPE.dic is written, e.g. ./system.dic
#
# CI uses this instead of sudachi.rs/fetch_dictionary.sh, which deletes the
# zip after extracting it, so there would be nothing to cache.
#
# The zip's sha256 is checked on every run, whether it was just downloaded or
# found in CACHE_DIR: a cache is only as trustworthy as whatever wrote it
# last. A zip that doesn't match is deleted and the script fails. CACHE_DIR
# only ever holds zips that matched, so it can be saved as it is.
#
# Exit status:
#   0  DEST written
#   1  the download failed or isn't the pinned file, or extracting failed
#   2  bad arguments
#   3  the zip already in CACHE_DIR isn't the pinned file (deleted). A CI
#      cache restores the same entry on every run, so callers that only warn
#      about a failed download should fail on this one.
#
# Running it again with the same arguments gives the same result. DEST is
# replaced in one step (extracted next to it, then renamed).
#
# SUDACHI_DICT_BASE_URL overrides where zips are downloaded from (default:
# the SudachiDict CDN); the URL is $SUDACHI_DICT_BASE_URL/FORMAT/NAME.zip,
# so a local copy can be served as file:///path/to/dir.

set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: $0 VERSION TYPE FORMAT SHA256 CACHE_DIR DEST" >&2
    exit 2
fi
VERSION="$1"
TYPE="$2"
FORMAT="$3"
SHA256="$(printf '%s' "$4" | tr 'A-F' 'a-f')"
CACHE_DIR="$5"
DEST="$6"

# VERSION and TYPE end up in a file name and a URL.
if [[ ! "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then
    echo "error: VERSION must be a SudachiDict release such as 20260723 (got '$VERSION')." >&2
    exit 2
fi
case "$TYPE" in
    small|core|full) ;;
    *) echo "error: TYPE must be small, core or full (got '$TYPE')." >&2; exit 2 ;;
esac
case "$FORMAT" in
    v0|v1) ;;
    *) echo "error: FORMAT must be v0 or v1 (got '$FORMAT')." >&2; exit 2 ;;
esac
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: SHA256 must be 64 hex digits (got '$4')." >&2
    exit 2
fi
if [ -z "$CACHE_DIR" ] || [ -z "$DEST" ]; then
    echo "error: CACHE_DIR and DEST must not be empty." >&2
    exit 2
fi

BASE_URL="${SUDACHI_DICT_BASE_URL:-https://d2ej7fkh96fzlu.cloudfront.net/sudachidict}"
NAME="sudachi-dictionary-$VERSION-$TYPE"
ZIP="$CACHE_DIR/$FORMAT/$NAME.zip"
DIC="system_$TYPE.dic"

# Partial files, removed on exit whatever happens, so CACHE_DIR never keeps
# an unverified download and DEST is never left half written.
PART=""
DEST_TMP=""
cleanup() {
    if [ -n "$PART" ]; then rm -f "$PART"; fi
    if [ -n "$DEST_TMP" ]; then rm -f "$DEST_TMP"; fi
}
trap cleanup EXIT

# Picked up front, so a missing tool (exit 1) isn't reported as a bad cached
# zip (exit 3).
if command -v sha256sum >/dev/null 2>&1; then
    SHA256_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    SHA256_CMD=(shasum -a 256)
else
    echo "error: neither sha256sum nor shasum is installed." >&2
    exit 1
fi
sha256_of() {
    "${SHA256_CMD[@]}" "$1" | cut -d ' ' -f 1
}

# Deletes $1 and fails unless its sha256 is $SHA256. (Explicit returns: it is
# called as an `if` condition, where `set -e` doesn't apply.)
verify_or_delete() {
    local file="$1" actual
    actual="$(sha256_of "$file")" || return 1
    if [ "$actual" != "$SHA256" ]; then
        rm -f "$file"
        echo "error: sha256 mismatch for $NAME.zip ($FORMAT); deleted $file" >&2
        echo "  expected: $SHA256" >&2
        echo "  actual:   $actual" >&2
        return 1
    fi
}

mkdir -p "$CACHE_DIR/$FORMAT"
if [ -f "$ZIP" ]; then
    echo "Using the cached $ZIP"
    if ! verify_or_delete "$ZIP"; then
        echo "  The cached zip is not the pinned file. If it came from a CI cache" >&2
        echo "  (actions/cache), delete that cache entry, e.g. with" >&2
        echo "  'gh cache list' and 'gh cache delete <key>', and run again." >&2
        exit 3
    fi
else
    URL="$BASE_URL/$FORMAT/$NAME.zip"
    echo "Downloading $URL"
    PART="$ZIP.part"
    # --retry-all-errors: also retry a connection reset or a transfer cut off
    # partway through the 137 MB full zip, which plain --retry doesn't.
    if ! curl --fail --location --silent --show-error --retry 3 --retry-all-errors --output "$PART" "$URL"; then
        echo "error: could not download $URL" >&2
        exit 1
    fi
    if ! verify_or_delete "$PART"; then
        echo "  The download is not the pinned file: it was corrupted on the way," >&2
        echo "  or SudachiDict replaced $NAME.zip. If the new file is intended," >&2
        echo "  update the pinned sha256 (the CI cache key follows it)." >&2
        exit 1
    fi
    mv -f "$PART" "$ZIP"
    PART=""
fi
echo "sha256 OK: $SHA256"

# The one entry named system_TYPE.dic (the zips also hold LEGAL and
# LICENSE-2.0.txt, under a sudachi-dictionary-VERSION/ directory).
if ! LISTING="$(unzip -Z1 "$ZIP")"; then
    echo "error: could not list the files in $ZIP" >&2
    exit 1
fi
ENTRY="$(printf '%s\n' "$LISTING" | awk -v dic="$DIC" '{ n = split($0, part, "/"); if (part[n] == dic) print }')"
if [ -z "$ENTRY" ] || [ "$(printf '%s\n' "$ENTRY" | wc -l)" -ne 1 ]; then
    echo "error: expected exactly one $DIC in $ZIP; it contains:" >&2
    printf '%s\n' "$LISTING" >&2
    exit 1
fi
# unzip reads its file arguments as wildcard patterns.
if [[ ! "$ENTRY" =~ ^[0-9A-Za-z._/-]+$ ]]; then
    echo "error: unexpected entry name in $ZIP: $ENTRY" >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST")"
DEST_TMP="$(mktemp "$(dirname "$DEST")/.fetch-test-dictionary.XXXXXX")"
if ! unzip -p "$ZIP" "$ENTRY" > "$DEST_TMP"; then
    echo "error: could not extract $ENTRY from $ZIP" >&2
    exit 1
fi
# mktemp creates it readable by its owner only.
chmod 644 "$DEST_TMP"
mv -f "$DEST_TMP" "$DEST"
DEST_TMP=""
echo "Wrote $DEST ($ENTRY, $(wc -c < "$DEST" | tr -d ' ') bytes)"
