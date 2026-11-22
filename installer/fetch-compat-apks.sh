#!/usr/bin/env bash
# Fetch and verify official open-source Android app store APKs (F-Droid & Aurora Store).
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$root/packages/compat-apks.sha256"
cache="${TSUKUYOMI_COMPAT_APK_CACHE:-$root/repo/compat-apks}"

mkdir -p "$cache"

verify_file() {
    local expected=$1 file=$2
    local actual
    [[ -s $file ]] || return 1
    actual=$(sha256sum "$file" | awk '{print $1}')
    [[ $actual == "$expected" ]]
}

while read -r expected name url; do
    [[ -n ${expected:-} && ${expected:0:1} != "#" ]] || continue
    dest="$cache/$name"
    if verify_file "$expected" "$dest"; then
        continue
    fi
    tmp="$dest.tmp.$$"
    printf 'Fetching %s...\n' "$name"
    if ! curl -fsSL --retry 2 --max-time 60 "$url" -o "$tmp"; then
        rm -f -- "$tmp"
        printf 'Failed to download %s from %s\n' "$name" "$url" >&2
        exit 1
    fi
    if ! verify_file "$expected" "$tmp"; then
        rm -f -- "$tmp"
        printf 'SHA-256 verification failed for %s\n' "$name" >&2
        exit 1
    fi
    mv -f -- "$tmp" "$dest"
done < "$manifest"

printf 'Verified compat APKs ready in %s\n' "$cache"
