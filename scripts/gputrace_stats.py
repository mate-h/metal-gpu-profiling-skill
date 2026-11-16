#!/usr/bin/env python3
"""Per-pipeline shader compiler statistics from a Metal capture (.gputrace).

A capture stores one NSKeyedArchiver plist per compiled pipeline function, named by a 16-digit hex
id: instruction counts by type, temporary/uniform registers, spilled bytes, threadgroup memory,
compile time, and the optimizer's remarks. Most entry points are named `main_` (naga), so each row
also lists the shader bindings that `device-resources-*` records just before that id, when it does
(only some pipelines are found there); the bindings usually identify the pass.

  gputrace_stats.py <x.gputrace> [--remarks <hex id>]
"""
import argparse, os, plistlib, re

ap = argparse.ArgumentParser()
ap.add_argument("trace")
ap.add_argument("--remarks", help="print the optimizer remarks of this pipeline id")
a = ap.parse_args()
G = a.trace

KEYS = [("Instruction count", "instr"), ("ALU instruction count", "ALU"), ("FP32 instruction count", "F32"),
        ("FP16 instruction count", "F16"), ("Texture reads instruction count", "tex"),
        ("Device load instruction count", "devld"), ("Device store instruction count", "devst"),
        ("Branch instruction count", "branch"), ("Temporary register count", "tmpReg"),
        ("Uniform register count", "uniReg"), ("Spilled bytes", "spill"), ("Threadgroup memory", "tgmem"),
        ("Compilation time in milliseconds", "ms")]


def resolve(objs, x):
    if isinstance(x, plistlib.UID):
        x = objs[x.data]
    if isinstance(x, dict):
        if "NS.keys" in x:
            return {resolve(objs, k): resolve(objs, v) for k, v in zip(x["NS.keys"], x["NS.objects"])}
        if "NS.objects" in x:
            return [resolve(objs, v) for v in x["NS.objects"]]
        if "NS.string" in x:
            return x["NS.string"]
    return x


def find(o, k):
    if isinstance(o, dict):
        if k in o:
            return o[k]
        o = list(o.values())
    if isinstance(o, list):
        for v in o:
            x = find(v, k)
            if x is not None:
                return x
    return None


rows = {}
for f in os.listdir(G):
    if not re.fullmatch(r"[0-9A-F]{8,16}", f):
        continue
    try:
        p = plistlib.load(open(f"{G}/{f}", "rb"))
        root = resolve(p["$objects"], p["$top"]["root"])
    except Exception:
        continue
    if find(root, "Temporary register count") is None:
        continue
    rows[f] = (find(root, "Function Name") or "?", {h: find(root, k) for k, h in KEYS}, find(root, "Remarks"))

if a.remarks:
    print(rows[a.remarks][2] or "(no remarks)")
    raise SystemExit

# Bindings: the resource table lists a pipeline's argument names before its stats id.
bindings = {}
dr = [f for f in os.listdir(G) if f.startswith("device-resources-")]
if dr:
    b = open(f"{G}/{dr[0]}", "rb").read()
    prev = 0
    for m in re.finditer(rb"[0-9A-F]{15,16}", b):
        f = m.group().decode()
        if f in rows:
            names = [re.sub(r"^_1bevy_(pbr_|render_|core_pipeline_)?", "", n.decode())
                     for n in re.findall(rb"_1bevy_\w+", b[prev:m.start()])]
            bindings[f] = list(dict.fromkeys(names))
            prev = m.end()


def cell(x):
    return "." if x is None else f"{x:.0f}" if isinstance(x, float) else str(x)


hdr = [h for _, h in KEYS]
print(f"{len(rows)} pipelines, sorted by temporary registers. spill = spilled bytes per thread.")
print(f"{'id':17s} {'function':24s} " + " ".join(f"{h:>6s}" for h in hdr))
for f, (name, st, _) in sorted(rows.items(), key=lambda kv: -(kv[1][1]["tmpReg"] or 0)):
    print(f"{f:17s} {str(name)[:24]:24s} " + " ".join(f"{cell(st[h]):>6s}" for h in hdr))
    if bindings.get(f):
        print(f"{'':17s}   bindings: {', '.join(bindings[f])[:150]}")
