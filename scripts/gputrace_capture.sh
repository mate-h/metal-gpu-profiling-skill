#!/bin/sh
# Metal frame capture (.gputrace) of a running app without Xcode: lldb attaches, starts
# MTLCaptureManager with a file destination, lets the app run MS milliseconds, stops and detaches.
# The app must have been started with MTL_CAPTURE_ENABLED=1 (and warmed up).
#
#   gputrace_capture.sh <pid> <out.gputrace> [ms (default 40)]
#
# A 40 ms capture of the Bevy atmosphere example is ~200 MB (resource contents dominate); delete
# it once the numbers are extracted. Read it with gputrace_stats.py, or open it in Xcode.
PID=${1:?pid}; OUT=${2:?out.gputrace}; MS=${3:-40}
HERE=$(cd "$(dirname "$0")" && pwd)
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ -e "$OUT" ] && { echo "$OUT exists"; exit 1; }
kill -0 "$PID" 2>/dev/null || { echo "process $PID not running"; exit 1; }
perl -e 'alarm 300; exec @ARGV' lldb -b -p "$PID" -o "command script import $HERE/gputrace_lldb.py" \
  -o "gputrace_capture $OUT $MS" 2>&1 | grep '^>'
[ -d "$OUT" ] || { echo "no capture written (was the app started with MTL_CAPTURE_ENABLED=1?)"; exit 2; }
echo "captured $(du -sh "$OUT" | cut -f1) to $OUT"
