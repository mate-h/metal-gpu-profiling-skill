#!/bin/sh
# One exact per-pass GPU measurement: launch <binary> [args...], warm up, attach a Metal System
# Trace, export the tables, delete the trace and its raw ktrace, print the per-pass table.
#
# Env: S       scratch folder (required); results kept in $S/xc/{gpu,enc}.xml only with KEEP_XML=1
#      WARM    seconds before attaching (default 45)      SECS   recording length (default 2)
#      FRAME   label of a once-per-frame pass (for ms/frame)   TOP   rows to print (default 25)
#      PID     attach to this already-running process instead of launching one (it is left running)
#      GPU_IDLE max "Device Utilization %" to wait for before launching (default 20; a desktop
#               alone can sit at 30-40%, raise it once the user says the GPU is free)
#      COUNTERS=0  skip the GPU counters (on by default: per-pass limiters, occupancy, bandwidth
#               and per-shader time; ~100 MB trace and ~0.5 GB XML per second, so keep SECS at
#               1-2). Recorded with a copy of the Metal System Trace template whose counter set
#               is COUNTER_PROFILE (default 13 = Performance Limiters on the M5; the number is
#               per GPU, the set's name is printed) and the shader timeline on.
#      PSTATE  induced GPU performance state for the recording (0 default, 3 maximum)
#      Counters need the GPU components Instruments installs on its first GUI launch
#      (see SKILL.md and references/counter-profiles.md).
# Run it in the foreground: saving the trace alone can take 5+ minutes.
S=${S:?set S to a scratch folder}; X="$S/xc"; mkdir -p "$X/tmp"
HERE=$(cd "$(dirname "$0")" && pwd)
GTMP=$(getconf DARWIN_USER_TEMP_DIR)
ls "$GTMP"instruments*.ktrace 2>/dev/null | sort > "$X/ktrace.before"

wait_xctrace() { while pgrep -qx xctrace; do sleep 15; done; }
wait_gpu() {
  n=0; while [ $n -lt 3 ]; do
    u=$(ioreg -r -c IOAccelerator -d 1 | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2)
    if [ "${u:-100}" -le "${GPU_IDLE:-20}" ]; then n=$((n+1)); else n=0; fi; sleep 2
  done
}
cleanup() {
  rm -rf "${X:?}/c.trace"; find "$X/tmp" -mindepth 1 -delete 2>/dev/null
  # DTServiceHub can hold this recording's ktrace for a while after the export; wait up to 60 s
  # for it before giving up (a still-held one may also be another live recording).
  ls "$GTMP"instruments*.ktrace 2>/dev/null | sort | comm -13 "$X/ktrace.before" - | while read -r k; do
    n=0; while lsof "$k" >/dev/null 2>&1 && [ $n -lt 12 ]; do sleep 5; n=$((n+1)); done
    lsof "$k" >/dev/null 2>&1 && echo "(ktrace still held, left in place: $k)" || rm -f "$k"
  done
}

wait_xctrace
if [ -n "$PID" ]; then
  APP=$PID; OWN=0
else
  [ $# -ge 1 ] || { echo "usage: S=... $0 <binary> [args...]"; exit 1; }
  wait_gpu
  "$@" > "$X/app.log" 2>&1 &
  APP=$!; OWN=1
  sleep "${WARM:-45}"
fi
kill -0 "$APP" 2>/dev/null || { echo "process $APP not running"; tail -5 "$X/app.log" 2>/dev/null; exit 1; }
NAME=$(ps -o comm= -p "$APP" | xargs basename)

wait_xctrace
rm -rf "${X:?}/c.trace"
TEMPLATE='Metal System Trace'; INSTR=""
if [ "${COUNTERS:-1}" = 1 ]; then
  STOCK="$(xcode-select -p)/../Applications/Instruments.app/Contents/Packages/GPU.instrdst/Contents/Templates/Metal System Trace.tracetemplate"
  if python3 -I "$HERE/xctrace_template.py" "$STOCK" "$X/counters.tracetemplate" \
       --profile "${COUNTER_PROFILE:-13}" --shader 1 --pstate "${PSTATE:-0}"; then
    TEMPLATE="$X/counters.tracetemplate"; INSTR=1
  else
    echo "(counters: could not make the counter template; recording without counters)"
  fi
fi
TMPDIR="$X/tmp/" perl -e 'alarm 900; exec @ARGV' xcrun xctrace record --template "$TEMPLATE" \
  --time-limit "${SECS:-2}s" --output "$X/c.trace" --attach "$APP" --no-prompt > "$X/rec.log" 2>&1
REC=$?
[ "$OWN" = 1 ] && kill "$APP" 2>/dev/null
if [ $REC -ne 0 ] || grep -qiE 'could not lock kperf|failed to start' "$X/rec.log"; then
  echo "recording failed (exit $REC):"; tail -5 "$X/rec.log"; cleanup; exit 2
fi
if [ -n "$INSTR" ] && grep -q 'counter profile is not supported' "$X/rec.log"; then
  echo "(counters: not supported by this Xcode on this GPU; see references/counter-profiles.md)"
  INSTR=""
fi
if [ -n "$INSTR" ]; then
  SET=$(xcrun xctrace export --input "$X/c.trace" --toc | grep -o 'Counter Set: [^<]*' | head -1)
  echo "(counters: ${SET:-Counter Set: ?} from COUNTER_PROFILE=${COUNTER_PROFILE:-13})"
  case "$SET" in *"Performance Limiters"*) ;; *)
    echo "WARNING: COUNTER_PROFILE=${COUNTER_PROFILE:-13} did not record Performance Limiters on this GPU."
    echo "         The default 13 was measured on an M5; counter set numbers differ per GPU and Xcode."
    echo "         Find yours in references/counter-profiles.md and rerun with COUNTER_PROFILE=<n>." ;;
  esac
fi
TABLES="metal-gpu-intervals:gpu metal-application-encoders-list:enc"
[ -n "$INSTR" ] && TABLES="$TABLES gpu-counter-info:gpu-counter-info gpu-counter-value:gpu-counter-value metal-shader-profiler-intervals:shaders"
for t in $TABLES; do
  xcrun xctrace export --input "$X/c.trace" \
    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"${t%%:*}\"]" > "$X/${t##*:}.xml"
done
cleanup
echo "process $NAME ($APP)"
python3 -I "$HERE/xctrace_passes.py" --gpu "$X/gpu.xml" --enc "$X/enc.xml" --proc "$APP" \
  ${FRAME:+--frame "$FRAME"} --top "${TOP:-25}"
if [ -n "$INSTR" ]; then
  echo
  NPY=""; for p in ${PY:-} python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    command -v "$p" >/dev/null 2>&1 && "$p" -I -c 'import numpy' 2>/dev/null && { NPY=$p; break; }
  done
  if [ -n "$NPY" ]; then
    "$NPY" -I "$HERE/xctrace_counters.py" --dir "$X" --proc "$APP" --top "${TOP:-25}"
  else
    echo "(counters: no python with numpy found; set PY=<python with numpy>, KEEP_XML=1 to keep the exports)"
  fi
fi
[ "$KEEP_XML" = 1 ] || rm -f "$X/gpu.xml" "$X/enc.xml" "$X/gpu-counter-info.xml" "$X/gpu-counter-value.xml" "$X/shaders.xml"
