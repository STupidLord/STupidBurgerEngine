# Rendering performance investigation

## Scope and stack verification

Verified `Directory.Build.props`: target framework `net8.0`. Verified `Burger.Game.csproj`: `Raylib-cs` 7.0.2. Changed only presentation code, render instrumentation, and this report: `src/Burger.Game/App.cs`, `src/Burger.Game/MapRenderer.cs`, new `src/Burger.Game/RenderPerf.cs`, and `docs/rendering-performance.md`. No `Burger.Core`, backend, tick scheduling, simulation, or gameplay-rule changes.

## Findings

The reported ~40 ms/frame baseline was **not reproducible in this sandbox**. The available display was Xvfb with software OpenGL forced (`LIBGL_ALWAYS_SOFTWARE=1`), not a user GPU. At 1280×720, paused Earth1930 rendered at a stable ~3.2 FPS before optimization. Nearly all elapsed time was rendering: map CPU stage ~291 ms/frame, `EndDrawing`/present stage ~22 ms/frame, simulation timing 0 ms/frame while paused. These numbers characterize this software-rendered environment, not the user's GPU.

Strongest proven bottleneck: Earth1930's terrain height mesh was 1024×576 (~590k height vertices) and disproportionately expensive in the software renderer. The full-resolution map-data texture carries province edges and map-mode colors independently. Earth now builds a 256×144 **render mesh** from the already-smoothed full-resolution heights; `_heights` remains 1024×576 for `HeightAt`, world positions, and ray-marched picking. Smaller maps retain their previous terrain mesh cap.

Tested densities in the same environment:

| Earth render mesh cap | Stable average FPS | Frame p50, approx. | Decision |
|---|---:|---:|---|
| 1024 baseline | 3.2 | 314 ms | Original |
| 768 | 3.8–3.9 | 254–262 ms | Rejected; less gain |
| 512 | 5.1–5.2 | 193 ms | Intermediate |
| 256 final | 9.0–9.1 | 111 ms | Kept; best tested |

The 256 screenshot remained visually close at the same scene and window size. Terrain relief is lower-resolution; map colors, boundaries, overlays, labels, units, and full-resolution picking heights remain driven by their original data.

## Matched Earth1930 measurements

Same game, paused observer state, 1280×720, default settings, Release build, Xvfb/software OpenGL. Warm-up/first 10-second window excluded. Values below are medians across four subsequent 10-second report windows; each window had about 32 baseline frames and 87–92 final frames.

| Metric | Baseline | Final | Change |
|---|---:|---:|---:|
| Average FPS | 3.2 | 9.1 | +184% |
| Frame p50 | 314 ms | 111 ms | −65% |
| Frame p95 | 336 ms | 122 ms | −64% |
| Frame p99 | 341 ms | 140 ms | −59% |
| Map stage p50 | 291 ms | 19 ms | −93% |
| Present stage p50 | 22 ms | 91 ms | Wait moved into `EndDrawing`; not GPU-only timing |
| Managed allocation | 32.3 KB/frame | 32.3 KB/frame | No material change |
| GC pauses during stable windows | 0 ms | 0 ms | No observed GC pause |
| Simulation (`LastUpdateMs`) | 0 ms/frame | 0 ms/frame | Paused in both runs |

The first report window contains startup/warm-up outliers; excluded above. Percentiles from later windows remain noisy at p99, particularly baseline with only ~32 samples per window.

## Lighter-scene check

`projects/GameTest/game`, 1280×720, same software-rendered setup: final steady measurements were ~5.4 FPS, frame p50 181–184 ms, p95 200 ms, p99 218–223 ms. Its map does not take the Earth-only mesh cap, so this render change does not materially affect it. This scene is lighter in world/map data, but the software-rendered display still imposes a large per-frame floor.

## Instrumentation

`--perf` now records 10-second windows using a fixed 600-frame ring buffer. Frame p50/p95/p99 and average FPS; per-thread allocations; GC collection deltas and pause duration; CPU timings for input/camera/picking, map, labels, orders, units, fleets, air overlays, hover, UI, and `EndDrawing`; simulation timing via existing `Clock.LastUpdateMs`.

Map timing includes shader setup, mesh draws, and any dirty visibility-LUT work/upload. It does not separately time one-time texture uploads. `EndDrawing` includes whatever present/swap blocking the driver performs; Raylib-cs 7.0.2 exposes no draw-call/batch count API or usable GPU timestamp-query counter here. No GPU time, upload time, batch count, or draw-call count is claimed.

## Validation

- `dotnet build src/Burger.Game/Burger.Game.csproj -c Release` — passed, zero errors. One pre-existing warning remains: `CS0414`, `MapRenderer._locLut` assigned but unused.
- Screenshot startup smoke runs passed for Political, Terrain, States, Diplomacy, Locations, Supply, and Air map modes.
- Zoomed screenshot at 1024×768 passed; Earth terrain, labels, divisions/fleet counters, and resized UI visible.
- Live Xvfb input smoke test: selected USA, clicked map to select a location, middle-dragged to pan, wheel-zoomed; screenshot showed selected location and 24 selected divisions. No runtime error logs.
- Country-panel startup smoke and other map-mode screenshot captures completed. Visual inspection confirmed Terrain mode, country panel, and zoom/resize rendering. No deterministic image-diff suite exists in the repository.
- Repository contains no test project. Hardware-GPU timing, high-resolution monitor testing, and pixel-identical comparisons on a real GPU were unavailable/not run.

## Reproduction

```bash
export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 LIBGL_ALWAYS_SOFTWARE=1
cd /home/ubuntu/WrektBurgerEngine
dotnet build src/Burger.Game/Burger.Game.csproj -c Release
timeout 55s xvfb-run -a dotnet src/Burger.Game/bin/Release/net8.0/Burger.Game.dll \
  --game projects/Earth1930/game --observe --perf --size 1280x720 --log-dir /tmp/render-perf
```
