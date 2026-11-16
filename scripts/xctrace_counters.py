#!/usr/bin/env python3
"""Per-pass GPU counters and per-shader GPU time from one Metal System Trace recorded with the
Metal GPU Counters instrument.

Inputs (in --dir): gpu-counter-info.xml, gpu-counter-value.xml, gpu.xml (metal-gpu-intervals),
enc.xml (metal-application-encoders-list), shaders.xml (metal-shader-profiler-intervals).

The counters are sampled GPU-wide, not per encoder: each pass gets the mean of the samples taken
inside its own GPU intervals, so passes that run concurrently mix. Trust rows of passes that
dominate their time span (big compute passes); vertex rows of small render passes usually just
overlap other work.

  xctrace_counters.py --dir <export dir> --proc <process name prefix or pid> [--top N]
"""
import argparse, collections, xml.etree.ElementTree as ET
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--dir", required=True)
ap.add_argument("--proc", required=True)
ap.add_argument("--top", type=int, default=20)
a = ap.parse_args()


def ours(fmt):
    fmt = fmt or ""
    return fmt.endswith(f"({a.proc})") if a.proc.isdigit() else fmt.startswith(a.proc)


def stream(path):
    """Rows as {column: (text, fmt)}, resolving xctrace's id/ref deduplication, streamed (the
    counter table is ~0.5 GB of XML for one second)."""
    vals = {}; cols = None
    for _, el in ET.iterparse(path, events=("end",)):
        if el.tag == "schema":
            cols = [c.findtext("mnemonic") for c in el.findall("col")]
        elif el.tag == "row":
            out = []
            for c in el:
                if "ref" in c.attrib:
                    out.append(vals[c.attrib["ref"]])
                else:
                    v = (c.text, c.attrib.get("fmt")); out.append(v)
                    for g in c.iter():
                        if "id" in g.attrib:
                            vals[g.attrib["id"]] = (g.text, g.attrib.get("fmt"))
            yield dict(zip(cols, out)); el.clear()


def num(v):
    return v[0] if v[0] is not None else v[1]


names = {int(num(r["counter-id"])): r["name"][1] or r["name"][0]
         for r in stream(f"{a.dir}/gpu-counter-info.xml")}
ts = collections.defaultdict(list); vs = collections.defaultdict(list)
for r in stream(f"{a.dir}/gpu-counter-value.xml"):
    c = int(num(r["counter-id"])); ts[c].append(int(num(r["timestamp"]))); vs[c].append(float(num(r["value"])))
T, V = {}, {}
for c in ts:
    t = np.array(ts[c]); o = np.argsort(t); T[c] = t[o]; V[c] = np.array(vs[c])[o]
if not T:
    raise SystemExit("no counter samples: was the trace recorded with a counter template (xctrace_template.py), "
                     "and is its counter set one this GPU supports? See references/counter-profiles.md.")

label = {num(r["encoder-id"]): r["encoder-label"][1] or r["encoder-label"][0]
         for r in stream(f"{a.dir}/enc.xml") if ours(r["process"][1])}
iv = collections.defaultdict(list)
for r in stream(f"{a.dir}/gpu.xml"):
    if num(r["event-depth"]) != "0" or not ours(r["process"][1]):
        continue
    l = label.get(num(r["encoder-id"]))
    if l:
        s = int(num(r["start"])); iv[(l, r["channel-name"][1] or r["channel-name"][0])].append((s, s + int(num(r["duration"]))))
if not iv:
    raise SystemExit(f"no labeled GPU intervals for {a.proc!r}")
span = max(e for v in iv.values() for _, e in v) - min(s for v in iv.values() for s, _ in v)

# Short headers for the counters worth a column; anything else the GPU reports is skipped.
# Names differ by GPU generation (M1 Pro vs M5), so each column lists its alternatives.
cols = [("ALU Limiter", "ALUlim"), ("Instruction Throughput Limiter", "InsLim"),
        ("ALU Utilization", "ALU"), ("F32 Utilization", "F32"), ("F16 Utilization", "F16"),
        ("Integer and Complex Limiter", "IntCx"), ("Control Flow Limiter", "CtlFlw"),
        ("Texture Sample Limiter|Texture Read Limiter", "TexRd"),
        ("Texture Filtering Limiter", "TexFlt"),
        ("Texture Cache Limiter|Texture Read Cache Limiter", "TexCch"),
        ("Texture Write Limiter", "TexWr"), ("Buffer Read Limiter", "BufRd"),
        ("Buffer Write Limiter", "BufWr"), ("L1 Cache Limiter", "L1"),
        ("GPU Last Level Cache Limiter|Last Level Cache Limiter", "LLC"), ("MMU Limiter", "MMU"),
        ("Vertex Occupancy|VS Occupancy", "VtxOcc"), ("Fragment Occupancy|FS Occupancy", "FrgOcc"),
        ("Compute Occupancy|Kernel Occupancy", "CmpOcc"),
        ("Register Pressure Influence", "RegPr"), ("Memory Request Stalls Influence", "MemSt"),
        ("GPU Read Bandwidth", "RdGB/s"), ("GPU Write Bandwidth", "WrGB/s")]
by_name = {n: c for c, n in names.items()}
cols = [(by_name[n], h) for alts, h in cols for n in alts.split("|")[:] if n in by_name]

print(f"capture {span / 1e6:.0f} ms. Counter means over each pass's own GPU intervals (%, GB/s); "
      f"GPU-wide counters, so concurrent passes mix.")
print(f"{'pass':40s} {'ms/s':>6s} " + " ".join(f"{h:>6s}" for _, h in cols))
for (l, ch), v in sorted(iv.items(), key=lambda kv: -sum(e - s for s, e in kv[1]))[:a.top]:
    cells = []
    for c, _ in cols:
        idx = np.concatenate([np.arange(np.searchsorted(T[c], s), np.searchsorted(T[c], e)) for s, e in v])
        cells.append(f"{V[c][idx].mean():6.1f}" if len(idx) else "     .")
    busy = sum(e - s for s, e in v)
    print(f"{(l + ' [' + ch + ']')[:40]:40s} {busy / span * 1e3:6.1f} " + " ".join(cells))

try:
    rows = list(stream(f"{a.dir}/shaders.xml"))
except FileNotFoundError:
    rows = []
if rows:
    allv = sorted((s, e, l) for (l, _), v in iv.items() for s, e in v)
    starts = np.array([x[0] for x in allv])
    t_sh = collections.defaultdict(float); where = collections.defaultdict(collections.Counter)
    for r in rows:
        if not ours(r["process"][1]) or num(r["event-depth"]) != "0":
            continue
        s = int(num(r["start"])); d = int(num(r["duration"])); n = r["name"][1] or r["name"][0]
        t_sh[n] += d
        k = int(np.searchsorted(starts, s, side="right")) - 1
        for j in range(max(0, k - 30), k + 1):
            if allv[j][0] <= s < allv[j][1]:
                where[n][allv[j][2]] += d
    print("\nshader timeline: GPU time per shader entry point (pipeline id in parentheses; good for "
          "ranking, not equal to encoder time), and the pass it mostly runs in")
    for n, d in sorted(t_sh.items(), key=lambda kv: -kv[1])[:a.top]:
        p = where[n].most_common(1)
        print(f"  {d / span * 1e3:8.2f} ms/s  {n:36s} {p[0][0] if p else '?'}")
