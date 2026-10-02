#!/bin/sh
# Zig's content-addressed build products can be rebuilt; keep packages and tools.
# Cap: 1 GiB. Zig 0.16.0 on arm64 macOS, 2026-10-02: du -sk .zig-cache
# after a cold `zig build test -Doptimize=Debug` measured 53728 KiB.
# Reserve six such suites for modes and rebuilds, rounded up to GiB; Linux starts fresh.
set -eu
cache=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/.zig-cache}
cap_kib=${2:-1048576}
case "$cap_kib" in ''|*[!0-9]*) echo 'cache: cap must be KiB' >&2; exit 2 ;; esac
[ "$cap_kib" -gt 0 ] || exit 2
[ ! -L "$cache" ] || { echo "cache: refusing symlink $cache" >&2; exit 2; }
[ -d "$cache" ] || exit 0
usage=$(du -sk "$cache")
size_kib=${usage%%[[:space:]]*}
if [ "$size_kib" -gt "$cap_kib" ]; then
    echo "cache: $size_kib KiB exceeds $cap_kib KiB; rebuilding products"
    rm -rf -- "$cache/o" "$cache/h" "$cache/z" "$cache/tmp"
fi
