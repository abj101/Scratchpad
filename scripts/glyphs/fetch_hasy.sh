#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
data_dir="$repo_root/build/hasy"
archive="$data_dir/HASYv2.tar.bz2"
url="https://zenodo.org/api/records/259444/files/HASYv2.tar.bz2/content"
expected_md5="fddf23f36e24b5236f6b3a0880c778e3"

mkdir -p "$data_dir"

md5_of() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | cut -d ' ' -f 1
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "$1"
    else
        echo "Need md5sum or md5 to verify the official Zenodo archive." >&2
        return 1
    fi
}

if [[ ! -f "$archive" ]]; then
    tmp="$archive.part.$$"
    trap 'rm -f "$tmp"' EXIT
    curl --fail --location --retry 3 --output "$tmp" "$url"
    mv "$tmp" "$archive"
    trap - EXIT
fi

actual_md5="$(md5_of "$archive")"
if [[ "$actual_md5" != "$expected_md5" ]]; then
    echo "HASYv2 archive checksum mismatch: expected $expected_md5, got $actual_md5" >&2
    exit 1
fi

if [[ -f "$data_dir/hasy-data-labels.csv" && -d "$data_dir/hasy-data" ]]; then
    printf 'HASYv2 already extracted under %s\n' "$data_dir"
    exit 0
fi

tar -xjf "$archive" -C "$data_dir"
printf 'HASYv2 extracted under %s\n' "$data_dir"
