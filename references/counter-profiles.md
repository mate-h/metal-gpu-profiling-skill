# Choosing a GPU counter set from the CLI

`xctrace record` has no flag for instrument options. The GPU counter settings live in the template
(`.tracetemplate`, an NSKeyedArchiver binary plist), in one dictionary with these keys:

| key | meaning |
|---|---|
| `counterprofile` | counter set (int, per GPU: below) |
| `shaderprofiler` | Shader Timeline on/off (bool) |
| `gpuperformancestate` | induced GPU performance state: 0 default, 3 maximum |
| `counterdevice` | GPU `registryID`; 0 = default. The ID changes across reboots, so leave it at 0 |
| `...internal`, `counters...` | GUI copies; the GUI's saved template leaves them stale, and they don't matter |

`scripts/xctrace_template.py` copies the stock template with `--profile`, `--shader` and
`--pstate` set. `xctrace_profile.sh` uses it by default (`COUNTER_PROFILE`, `PSTATE`).

## Counter set numbers

The numbers depend on the GPU and toolchain. Check what a number means in the recorded trace:
`xctrace export --toc` lists "Counter Set: <name>" under the run's recording settings, and the
`gpu-counter-info` table carries `counter-profile="<n>"`. To learn the number for a set on a new
machine, choose the set in the Instruments GUI (Metal Application > Counter Set), use File > Save
As Template, and read `counterprofile` from the saved file.

- **M5, Xcode 27.2, macOS 27.2:** 13 = Performance Limiters (88 counters). On this machine 2 was
  named Raw Limiters, 3 Performance Limiters, 4 Performance Utilizations, 5 Render Basic, 6 Compute
  Basic and 7 Rasterizer and Pixel Backend, but before the GUI component install those sets
  recorded nothing or only "RT Unit Active". 3 hasn't been retested since then.
- `--instrument 'Metal GPU Counters'` adds a second counter instance (Performance Limiters by its
  own number, shader timeline on) next to the template's own (null set). On the M5 that records
  nothing; on the M1 Pro it worked.

## Prerequisites (M5, Nov 2026)

1. **Xcode 27.2.** Xcode 26.4 rejects every set with "Selected counter profile is not supported on
   target device" (a warning in the record log, exit code 0). Its GPU tools know families only up
   to `applegpu_g15p`; the M5 is G17G (`ioreg -r -c IOAccelerator -d 1 -l | grep IOClass`).
2. **macOS 27.2** (tested together with step 3, so which of the two mattered isn't known).
3. **Launch the Instruments GUI once.** It installs GPU system components ("Installing System
   Components..."). Before that, every set gave no counters or only "RT Unit Active", with no
   error anywhere.

macOS ships derived-counter scripts (`AGXMetalStatisticsExternal*-derived.js` in
`/System/Library/Extensions/AGXMetal<family>.bundle`) only for G13/G14; newer families get them
from the tools. The Command Line Tools package has no Instruments.

## Checking a recording

List the names in `gpu-counter-info`, don't just count rows: a single counter ("RT Unit Active")
still gives ~250k value rows per second. The shader timeline (`metal-shader-profiler-intervals`)
on the M5 is filled in some recordings and empty in others, even with the same settings; the PC
samples (`gpu-shader-profiler-interval`) are more reliable.
