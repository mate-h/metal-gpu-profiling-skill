#!/usr/bin/env python3
"""Copy the stock Metal System Trace template with the GPU counter instrument's settings changed.

xctrace has no flags for instrument options; they live in the template (an NSKeyedArchiver plist).
The counter profile numbers depend on the GPU: on the M5 (Xcode 27.2) Performance Limiters is 13,
and `--instrument 'Metal GPU Counters'` picks one that records nothing there. The recorded trace's
TOC names the set that was used ("Counter Set: ..."). See references/counter-profiles.md.

  xctrace_template.py <src.tracetemplate> <dst.tracetemplate> --profile N [--shader 0|1] [--pstate N]
"""
import argparse, plistlib

ap = argparse.ArgumentParser()
ap.add_argument("src"); ap.add_argument("dst")
ap.add_argument("--profile", type=int, required=True, help="counterprofile (M5: 13 = Performance Limiters)")
ap.add_argument("--shader", type=int, default=1, help="shader timeline on (1) / off (0)")
ap.add_argument("--pstate", type=int, default=0, help="induced GPU performance state (0 default, 3 maximum)")
a = ap.parse_args()

p = plistlib.load(open(a.src, "rb")); objs = p["$objects"]


def s(x):
    x = objs[x.data] if isinstance(x, plistlib.UID) else x
    return x.get("NS.string", x) if isinstance(x, dict) else x


values = {"counterprofile": a.profile, "shaderprofiler": bool(a.shader), "gpuperformancestate": a.pstate}
n = 0
for o in objs:
    if isinstance(o, dict) and "NS.keys" in o:
        keys = [s(k) for k in o["NS.keys"]]
        if "counterprofile" not in keys:
            continue
        for i, k in enumerate(keys):
            if k in values:
                objs.append(values[k]); o["NS.objects"][i] = plistlib.UID(len(objs) - 1)
        n += 1
if n != 1:
    raise SystemExit(f"expected one counter settings dictionary in {a.src}, found {n}")
plistlib.dump(p, open(a.dst, "wb"), fmt=plistlib.FMT_BINARY)
