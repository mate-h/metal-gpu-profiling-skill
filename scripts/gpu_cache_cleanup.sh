#!/bin/sh
# Deletes the per-process Metal shader-archive folders that pile up in the user cache:
#   $(getconf DARWIN_USER_CACHE_DIR)com.apple.gpuarchiver/gpuarchiver-XXXXXX
# Each Metal process that compiles pipelines leaves one (descriptors, reflection, AIR and GPU
# binaries, up to ~60 MB) and nothing removes them: 457 folders / 15 GB after a few weeks of
# capture, replay and app runs (Nov 2026). Skips folders a running process has open and those
# modified in the last MIN minutes (default 10), which may belong to an app that is starting.
#   gpu_cache_cleanup.sh [MIN] [--dry-run]
set -e
min=${1:-10}
case "$min" in --dry-run) min=10 ;; esac
dry=0; for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; done
dir="$(getconf DARWIN_USER_CACHE_DIR)com.apple.gpuarchiver"
[ -d "$dir" ] || { echo "no $dir"; exit 0; }
held=$(lsof -Fn 2>/dev/null | sed -n 's|^n.*com\.apple\.gpuarchiver/\(gpuarchiver-[0-9a-f]*\).*|\1|p' | sort -u)
n=0; kept=0; freed=0
for d in $(find "$dir" -mindepth 1 -maxdepth 1 -type d -name 'gpuarchiver-*' -mmin +"$min"); do
    b=$(basename "$d")
    if printf '%s\n' "$held" | grep -qx "$b"; then kept=$((kept + 1)); continue; fi
    freed=$((freed + $(du -sk "$d" | cut -f1)))
    [ "$dry" = 1 ] || rm -rf "$d"
    n=$((n + 1))
done
after=$(du -sk "$dir" | cut -f1)
verb=removed; [ "$dry" = 1 ] && verb="would remove"
echo "$verb $n folders ($((freed / 1024)) MB), kept $kept in use; $dir is now $((after / 1024)) MB"
