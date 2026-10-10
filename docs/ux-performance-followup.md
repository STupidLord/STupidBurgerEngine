# UX and frame-time follow-up

## Why the reported run is still slow

The provided steady sample says **15.0 FPS = 66.6 ms per frame**. It does **not** show a slow simulation: `simulation ... 0.7 ms/frame`. `input/pick` is at most 0.4 ms. UI and map CPU-submission timings are also small.

The elapsed time is concentrated in `present` (about 66 ms). That measurement wraps `Raylib.EndDrawing()`, which flushes Raylib's queued 2D/3D batches, submits/executes GPU work, swaps buffers, and can block on the graphics driver/compositor or VSync. Consequently, `map 0.0/0.5 ms` means the CPU spent little time *submitting* the map calls; it does not mean the GPU rendered the map in 0.5 ms. Raylib-cs here provides no GPU timestamp query, so the sample cannot distinguish GPU execution from swap/VSync/compositor wait.

The game requests both `ConfigFlags.VSyncHint` and `Raylib.SetTargetFPS(120)`. VSync/driver/display pacing is therefore a leading suspect; 66 ms can also mean the renderer misses multiple display deadlines. The log alone cannot prove which. Check the game's actual graphics renderer and GPU utilization, display refresh rate, resolution/fullscreen mode, and whether it runs through Remote Desktop/virtual display. If disabling VSync is tested, do it as a diagnostic comparison only; do not treat uncapped FPS as the user-facing fix or alter simulation timing.

This is a different profile from the earlier sandbox run. That run explicitly used Mesa **llvmpipe software rendering** and the Earth height mesh dominated CPU time; this supplied log shows the map CPU stage is now cheap and `EndDrawing` is where time disappears. Do not apply further terrain simplification based on this log alone.

`RenderPerf` now labels that final stage `EndDrawing/flush+swap`, not `present`, to avoid implying a measured GPU or pure swap duration.

## UX audit and changes

Inspected live builds at Earth1930 and the small `GameTest` map, plus the Studio editor. Largest clear gameplay issues addressed:

- The left action rail showed many recognizable icons but cramped 11 px labels. Widened from 66 to 78 scaled pixels and raised labels to 12 px. Feature-gated filtering remains intact: Navy/Air/etc. only appear when their features are installed.
- The clock displayed only `PAUSED` instead of the campaign date. Date now stays visible with a colored `PAUSE`/`LIVE` badge; hovering exposes game speed and camera controls.
- Map-mode hover text described only the mode name. Tooltips now explain built-in semantics and numeric low/high RGB ranges for custom map modes.

Studio has an established preset/feature wizard, viewport, Inspector, Content Browser, error checking, save, play and export flows. This pass found no safe, clearly isolated Studio change that improved those workflows without risking its dock/persistence behavior. Baseline Studio was launched and inspected; `--selftest` exceeded a 90-second limit in this environment and is **not** reported as passing. No Studio source was changed.

## Validation

- `dotnet build src/Burger.Game/Burger.Game.csproj -c Release`: passed.
- `dotnet build src/Burger.Studio/Burger.Studio.csproj -c Release`: passed.
- New screenshots: Earth1930 USA at 1280×720; small GameTest at 1024×768 in States mode. Date, pause badge, expanded feature-gated rail, map and counter visibility checked.
- Previous render-pass checks remain: seven Earth1930 map modes, 1024×768 zoom/resize, live selection/pan/zoom, and country/location inspectors. UX edits preserve those existing drawing and action handlers.
- Existing warnings: Game's unused `_locLut` field; Studio's nullable dereference and unused `_newTemplate` field. No test project exists. `--selftest` timeout above; physical GPU, VSync on/off, hardware monitor, and remote-display A/B tests remain unrun.
