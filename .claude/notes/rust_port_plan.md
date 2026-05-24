# Rust port plan (Phase 2)

Replace the slimmed FTE engine with a from-scratch Rust client, scoped
solely to QuakeWorld for quake.world. No legacy/backwards-compatibility
burden.

Spec dependency: this port's feature surface is defined by whatever
survives [slim_plan.md](slim_plan.md). Don't start coding until that
config is locked.

Reference of what FTE currently exposes:
[build_configurability.md](build_configurability.md).

## Use cases (targets)

| Target | Binary | Driver | Notes |
|---|---|---|---|
| Web app | wasm | JS bindings | Controlled by slipgate. Local in-process server required for map preview + screenshot framing. Renders to canvas. |
| CLI batch | unix native | argv / scripts | Headless. Spawns on a map, sets pos/angle, writes screenshots or pipes frames to ffmpeg for mpeg capture. Short-lived per invocation. |
| Streambot | unix native | service | Long-running. Queries server-selection API → joins best live QW server → renders continuously (headless or windowed) → OBS captures framebuffer + audio → streams to Twitch/YouTube. Needs real audio output. |

All three use the same engine crate. The web target compiles via
`wasm32-unknown-unknown` (or `wasm32-wasi` if WASI features are
useful). The unix targets share one binary that switches between
headless / windowed modes based on flags.

## Renderer: wgpu

Single codebase covers all three targets:

- Web: wgpu → WebGPU (or WebGL2 fallback).
- Unix windowed: wgpu → Vulkan.
- Unix headless: wgpu → Vulkan with no swapchain; render to texture,
  read back to CPU for screenshot/ffmpeg pipeline.

OBS capture of the windowed unix build works the standard way (X11 /
Wayland window capture, plus PulseAudio/PipeWire audio capture).

## Subsystems

Each is its own Rust module/crate; listing roughly in build order.

| Subsystem | Notes |
|---|---|
| **Filesystem** | PAK (Q1), PK3 (zip) reads. No write. Resolve game-dir layered loading the way Quake does. |
| **BSP loader** | Q1 BSP (29) at minimum. Plus whatever modern variants the slim plan keeps (BSP2 likely). Output: vertex/index buffers, lightmaps, leaf/PVS, collision hulls. |
| **MDL / SPR loader** | Q1 model + sprite formats. Plus MD3 if the slim plan keeps it. |
| **Image decoders** | PNG (browser provides on web; `png` crate on unix), TGA, LMP, PCX. Plus JPG if kept. |
| **WAV / audio decode** | WAV mandatory. Audio output via cpal on unix; Web Audio API via wasm-bindgen on web. |
| **Video capture (CLI)** | For the unix CLI demo->mpeg use case: render frame to wgpu texture, copy_texture_to_buffer, read pixels back, pipe raw RGBA to `ffmpeg` via stdin (subprocess). `ffmpeg` binary is the runtime dependency, not a Rust library. Avoids FTE's avplug-style FFmpeg-as-loadable-library complexity. |
| **Renderer** | wgpu pipeline for BSP world rendering + alias models + sprites + particles + 2D HUD. Mirror the visual output of FTE's GL path. |
| **Network** | QW protocol (packets), with FTE/ezQuake protocol extensions as needed. UDP on unix; WebSocket bridge on web (a WS-to-UDP relay is the standard pattern). |
| **QC interpreter** | Required for the local server's worldspawn + entity logic. Pure interpreter over standard QC bytecode. Whether to also support QVM bytecode depends on the slim plan's VM_Q1 decision. |
| **Local server** | Spawn worldspawn, accept loopback client, run QC physics callbacks, send entity updates. Needed for map preview and screenshot use cases. |
| **Client prediction / movement** | QW movement physics (well-documented). |
| **Demo playback** | QWD + MVD parsers. NQ .dem optional. |
| **HUD / console / cvars** | Engine HUD baseline. Replicate ezhud's visible features (configurable layout, frags, stats) — but redesign the API; no need to mirror ezhud's C++ insides. |
| **JS bindings (web)** | wasm-bindgen surface for the slipgate web app to drive the engine (load map, set angle, take screenshot, connect to server, etc.). Mirror the affordances FTE's `ftejslib.{js,h}` provides today. |
| **CLI driver (unix)** | argv parser, headless mode, screenshot output, ffmpeg pipe for mpeg capture. |
| **Streambot driver (unix)** | Server-selection API client, auto-spectate logic, long-running event loop. |

## Phasing within the rewrite

Suggested order to land working slices early:

1. **BSP + renderer (demo playback)** — load a map, render with a
   free-fly camera, no networking, no server. Validates wgpu pipeline
   + asset loaders.
2. **Demo playback** — parse a QWD, render the recorded match.
   First end-to-end visible artifact.
3. **Local server + QC interpreter** — spawn on a map with full
   entities; unblocks map preview + screenshot use cases.
4. **Web binding + slipgate integration** — replace ftewebgl.wasm.
   First user-facing win.
5. **CLI screenshot/mpeg** — unblocks the batch use case.
6. **Live QW client (UDP / WebSocket)** — connect to a real server.
7. **Streambot** — server-selection API + spectator loop.

Steps 1-4 deliver the web replacement. Steps 5-7 deliver the unix
side.

## Open questions

These mostly resolve once the slim FTE config is locked, but worth
calling out:

- **QC interpreter scope** — interpret source-form QC, compiled
  bytecode (`progs.dat`), or QVM (`.qvm`)? Depends on slim plan's
  CSQC and VM_Q1 decisions, and on what mods the bot needs to run.
- **Web networking** — confirm WebSocket-to-UDP relay is acceptable
  for live-server connections from the browser, or whether the web
  build is preview/demo-playback only (no live).
- **Audio formats** — WAV is enough for vanilla. OGG for music?
  Opus for voice? Match slim plan decisions.
- **Console / cvar surface** — should the Rust client expose Quake
  cvars/commands to JS for slipgate to script, or use a Rust-native
  config layer?
- **Crate boundaries** — single `qworld` crate vs split (e.g.
  `qworld-bsp`, `qworld-net`, `qworld-render`). Defer until the
  shape is clearer.

## Out of scope explicitly

- Singleplayer Quake gameplay
- NetQuake protocol
- Q2 / Q3 / Hexen2 / Half-Life support of any kind
- Mod tooling (QC compiler, level editor)
- Server hosting (the local server exists only to spawn a client
  on a map; it doesn't accept external connections)
- VR / WebXR
- Splitscreen
