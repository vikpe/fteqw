# qworld — Rust port of the slim FTE engine

Scope: a from-scratch Rust client serving quake.world. Replaces the
slim-FTE wasm + provides unix CLI and streambot binaries.

See `.claude/notes/rust_port_plan.md` (parent repo) for the overall
design rationale, use cases, and phasing.

## Status

Workspace + initial port scaffold landed. Everything compiles on
native (Linux/Mac/Windows via wgpu's Vulkan/Metal/DX12) and the
wasm-bindgen surface compiles too. **39 tests passing** (cargo
test --workspace).

End-to-end milestone reached: `qworld render <map.bsp> --out shot.png`
produces an isometric overview PNG of any Q1 BSP, **both V29 and
BSP2** (verified on dm3 / povdmm4 / dust2qw).

Real implementations so far:

- `qworld-core` — shared types (Vec3, Angles, Bbox, color, ID newtypes) + embedded `QUAKE_PALETTE` const (vanilla id1 palette, decoded at compile time) + `load_palette` for custom palettes
- `qworld-fs` — PAK header/entry parsing (Q1/Q2 format) + PK3 via `zip`
- `qworld-bsp` — Q1 BSP **v29 + BSP2**: magic detection, 15 lump directory + entity-string parser + geometry decoders (vertexes/edges/surfedges/faces — V29 widens to BSP2 32-bit shape on read, in-memory types are always BSP2-shaped) + `face_vertices` polygon resolver + `texinfo` + `miptex` (with missing-entry handling) + `lighting_bytes` raw lightmap accessor
- `qworld-mdl` — Full MDL decoder: header, skins (single + group), stverts (with seam-wrap UVs), triangles, frames (single + group), `TriVertx::position` decompression, `Skin::to_rgba(palette)` for PNG export. SPR header parser.
- `qworld-image` — LMP (Quake-palette indexed) decoder + PCX via `pcx` crate + PNG/TGA/JPG via `image`
- `qworld-wav` — WAV decode via `hound`
- `qworld-demo` — QWD block reader, MVD message types, NQ .dem block reader, format sniffer
- `qworld-server` — local in-process server: parses BSP entities, picks `info_player_*` spawn point natively (no QC)
- `qworld-render` — wgpu GPU context + `HeadlessTarget` (color + optional depth) + `MeshPipeline` with WGSL shader, `Vertex`/`Mesh`, camera uniform. Real triangle rendering verified end-to-end.
- `bins/qworld-cli` — working `qworld pak list/extract`, `qworld bsp info/spawn`, `qworld demo sniff`, `qworld render <bsp> --out <png>` commands (clap-driven)

`todo!()` stubs (signatures + module structure documented; bodies
deferred):

- `qworld-net` — netchan, protocol version constants, FTE PEXT flags, svc message enum
- `qworld-shader` — Q3 shader/material model (parser TBD)
- `qworld-engine` — orchestrator skeleton
- `bins/qworld-web` — wasm-bindgen Engine handle with load_map / set_angle / screenshot stubs

## Crates / production deps used

| Concern | Crate | Notes |
|---|---|---|
| Binary parsing | `binrw` | declarative parsers for demo/net formats |
| Endian I/O (small parsers) | `byteorder` | for PAK/BSP/MDL where binrw would be overkill |
| Math | `glam` | wgpu-friendly vectors/matrices |
| Errors (libs) | `thiserror` | typed error enums |
| Errors (bins) | `anyhow` | terse propagation |
| ZIP (PK3) | `zip` | deflate support |
| PCX | `pcx` | tiny well-tested decoder |
| Common image (PNG/TGA/JPG) | `image` | feature-gated to just what we need |
| WAV | `hound` | RIFF parser + sample iterator |
| Renderer | `wgpu` 22 | + `bytemuck`, `futures-intrusive`, `pollster` |
| CLI | `clap` (derive) | |
| Logging | `tracing`, `tracing-subscriber`, `tracing-wasm` | |
| Web bindings | `wasm-bindgen`, `js-sys`, `web-sys`, `console_error_panic_hook` | |
| Test fixtures | `tempfile` | dev-only |

Quake-specific binary formats (PAK, BSP, MDL, SPR, demo protocols,
QW/NQ netchan) have no maintained Rust crates, so those are
hand-rolled with reference notes from the parent repo's `specs/`
docs and id1's known layouts.

## Use cases (from rust_port_plan.md)

1. **Web (wasm)** — replaces ftewebgl.{js,wasm}. Local in-process
   server required for map preview + screenshot framing. Driven from
   JS via wasm-bindgen surface in `bins/qworld-web`.
2. **Unix CLI (batch)** — screenshots + demo->mpeg capture. Pipes
   raw RGBA frames to `ffmpeg` subprocess. `bins/qworld-cli`.
3. **Streambot service** — long-running unix native, joins live QW
   servers, OBS captures the window/headless output for streaming.
   Same binary as CLI with different mode flags.

## Workspace layout

```
rust_port/
  Cargo.toml          # workspace
  crates/
    qworld-core/      # shared types (Vec3, color, ids)
    qworld-fs/        # PAK / PK3 readers
    qworld-bsp/       # Q1 BSP loader
    qworld-mdl/       # Q1 MDL / SPR loader
    qworld-image/     # PNG/TGA/LMP/PCX decoders
    qworld-wav/       # WAV decoder
    qworld-shader/    # Q3-style shader parser
    qworld-demo/      # QWD/MVD/NQ demo file parsers
    qworld-net/       # QW + NQ network protocols
    qworld-render/    # wgpu renderer
    qworld-server/    # local in-process server
    qworld-engine/    # orchestration
  bins/
    qworld-cli/       # unix CLI (screenshot, mpeg, streambot)
    qworld-web/       # wasm-bindgen surface for slipgate
```

## What was intentionally skipped

- **QC interpreter** — Quake's gamecode VM. The Rust port does not
  embed one. Reasoning:
  - The local in-process server only spawns a player so we have a
    camera for preview/screenshot. Native Rust handles `info_player_*`
    placement directly; no QC needed.
  - For live gameplay (streambot use case), the engine is a client
    only — the remote server runs QC, we just render entity updates.
  - For HUD (KTX uses CSQC), the Rust client builds its own HUD
    natively (Rust HUD module, not engine plug-in).
- **Runtime plugin loader** — slim FTE has none either (everything
  statically linked). The Rust crate boundary serves the same
  modularity role.

## Build

```sh
cd rust_port
cargo build --workspace
cargo run --bin qworld-cli -- --help
```

Web target (TODO):
```sh
cd rust_port/bins/qworld-web
wasm-pack build --target web --release
```

## Tests

```sh
cargo test --workspace
```

CI runs `cargo check --workspace`, `cargo test --workspace --exclude
qworld-render` (skipping GPU-required tests), `cargo fmt --check`,
and `cargo clippy -- -D warnings`. See `.github/workflows/ci.yml`.

## Roadmap (per `rust_port_plan.md`)

Suggested order to land working slices early:

1. **BSP renderer (free-fly camera)** — render geometry from a
   loaded Q1 BSP. Validates wgpu pipeline + asset loaders end-to-end.
2. **Demo playback** — parse a QWD, render the recorded match.
   First end-to-end visible artifact.
3. **Local server + native spawn** — already scaffolded
   (`qworld-server`); plug into engine for map preview.
4. **Web binding + slipgate integration** — replaces
   ftewebgl.wasm. First user-facing win.
5. **CLI screenshot / mpeg** — unblocks the batch use case.
6. **Live QW client (UDP / WebSocket)** — connect to a real server.
7. **Streambot** — server-selection API + spectator loop.
