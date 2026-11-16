#!/usr/bin/env python3
"""Exact per-pass GPU time from one Metal System Trace export.

Inputs: gpu.xml (table metal-gpu-intervals) and enc.xml (table metal-application-encoders-list).
Labels come from the encoder list joined on encoder-id. Each encoder's time per channel
(Vertex/Fragment/Compute) is the envelope of its depth-0 intervals. GPU rows whose encoder
has no label are skipped. Prints ms/frame, median ms per execution and executions/frame, and the
GPU busy time per frame (union of all intervals). Envelopes include time spent alongside other
passes, so per-pass numbers overstate a pass's own cost and do not add up to the busy time;
back frame-level claims with the busy time.

  xctrace_passes.py --proc <process name or pid> [--frame <once-per-frame label>] [--top N]
"""
import argparse, collections, statistics, xml.etree.ElementTree as ET

ap = argparse.ArgumentParser()
ap.add_argument("--gpu", default="gpu.xml")
ap.add_argument("--enc", default="enc.xml")
ap.add_argument("--proc", required=True, help="process name prefix, or pid")
ap.add_argument("--frame", help="label of a pass that runs once per frame, used to count frames")
ap.add_argument("--top", type=int, default=25)
a = ap.parse_args()


def ours(node):
    fmt = node.attrib.get("fmt", "")
    return fmt.endswith(f"({a.proc})") if a.proc.isdigit() else fmt.startswith(a.proc)


def rows(path):
    root = ET.parse(path).getroot()
    ids = {n.attrib["id"]: n for n in root.iter() if "id" in n.attrib}
    cols = [c.findtext("mnemonic") for c in root.find(".//schema").findall("col")]
    for row in root.findall(".//row"):
        yield dict(zip(cols, [ids[n.attrib["ref"]] if "ref" in n.attrib else n for n in row]))


def text(node):
    return node.attrib.get("fmt", node.text or "?")


label = {c["encoder-id"].text: text(c["encoder-label"]) for c in rows(a.enc) if ours(c["process"])}
env = {}; spans = []
for c in rows(a.gpu):
    if c["event-depth"].text != "0" or not ours(c["process"]) or c["encoder-id"].text not in label:
        continue
    key = (c["encoder-id"].text, text(c["channel-name"]))
    s = int(c["start"].text); e = s + int(c["duration"].text)
    lo, hi = env.get(key, (s, e)); env[key] = (min(lo, s), max(hi, e)); spans.append((s, e))
if not env:
    raise SystemExit(f"no labeled GPU intervals for {a.proc!r}: {len(label)} labeled encoders; "
                     "are passes labeled, and was the process attached after warm-up?")

per = collections.defaultdict(list); first = {}
for (enc, ch), (lo, hi) in env.items():
    per[(label[enc], ch)].append((hi - lo) / 1e6)
    if label[enc] == a.frame:
        # One start per encoder: a render pass has Vertex and Fragment rows, and counting both
        # doubled the frame count.
        first[enc] = min(first.get(enc, lo), lo)
starts = sorted(first.values())
if len(starts) > 1:
    frames = len(starts) - 1
    lo, hi = starts[0], starts[-1]
    busy = 0; cs = ce = None
    for s, e in sorted((max(s, lo), min(e, hi)) for s, e in spans if e > lo and s < hi):
        if ce is None or s > ce:
            busy += 0 if ce is None else ce - cs; cs, ce = s, e
        else:
            ce = max(ce, e)
    busy += 0 if ce is None else ce - cs
    print(f"frames {frames}, wall {(hi - lo) / 1e6 / frames:.2f} ms/frame, GPU busy (union) "
          f"{busy / 1e6 / frames:.2f} ms/frame, labeled encoders {len(label)}")
else:
    span = (max(h for _, h in env.values()) - min(l for l, _ in env.values())) / 1e6
    frames = 1
    print(f"no --frame marker; totals are for the whole {span:.0f} ms capture, labeled encoders {len(label)}")
for (l, ch), v in sorted(per.items(), key=lambda kv: -sum(kv[1]))[:a.top]:
    print(f"{sum(v) / frames:8.3f} ms/frame  median {statistics.median(v):7.3f} ms  x{len(v) / frames:4.1f}/frame  {ch:8s} {l[:70]}")
