# Rust port — session handoff

This is a from-scratch Rust quake client targeting **web (wasm) + unix
CLI + streambot**, replacing the slim FTE C engine for quake.world.
Project lives under `fteqw/rust_port/` even though long-term it may
move out — for now it sits next to the FTE source for reference.

When picking this up from `/home/vikpe/dev/slipgate/` (or any cwd
above `rust_port/`), run cargo with `--manifest-path` or `cd rust_port`
first.

## Quick start

```sh
cd fteqw/rust_port
cargo check --workspace --all-targets
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo run --bin qworld -- --help
```

Last verified clean: edition 2024, rustc 1.95+, **39 tests passing**,
clippy `-D warnings` green.

## What's in (real implementations)

| Crate | Status | Notes |
|---|---|---|
| `qworld-core` | Real | Vec3/Angles/Bbox/color/IDs + embedded `QUAKE_PALETTE` const (vanilla id1 768-byte palette, decoded at compile time) + runtime `load_palette` for custom palettes |
| `qworld-fs` | Real | PAK reader (full), PK3 via `zip` crate |
| `qworld-bsp` | Real | Q1 BSP **v29 + BSP2**: version detection from magic, lump dir, entity-string parser, geom decoders (vertexes/edges/surfedges/faces — V29 widens to BSP2 shape on read) + `face_vertices` polygon resolver, texinfo + miptex (with missing-entry handling) + `lighting_bytes` raw lightmap accessor |
| `qworld-mdl` | Real | Full MDL parse: header + skins (single & groups) + stverts + triangles + frames (single & groups) + `TriVertx::position`/`StVert::uv` helpers + `Skin::to_rgba(palette)` for PNG export |
| `qworld-image` | Real | LMP (Quake-palette), PCX via `pcx`, PNG/TGA/JPG via `image` |
| `qworld-wav` | Real | WAV decode via `hound` |
| `qworld-demo` | Partial | Format sniff, NQ block reader, QWD block reader, MVD message-type enum |
| `qworld-server` | Real for previews | `LocalServer::spawn_on_map` — parses BSP entities, picks `info_player_*` spawn natively (no QC) |
| `qworld-engine` | Real for previews | `Engine::load_map` → spawn server; exposes camera origin/yaw |
| `qworld-render` | Real (basic) | wgpu `GpuContext`, `HeadlessTarget` (color + optional depth), `MeshPipeline` with WGSL shader, `Vertex`/`Mesh` types, camera uniform. End-to-end triangle render verified via test. |
| `qworld-net` | Stubs only | netchan transmit/process are `todo!()`; protocol consts + svc enum scaffolded |
| `qworld-shader` | Stubs only | Q3 shader data model defined; parser is `todo!()` |
| `bins/qworld-cli` | Real | `qworld pak list/extract`, `qworld bsp info/spawn`, `qworld demo sniff`, `qworld render <bsp> --out <png>`. Integration-tested. |
| `bins/qworld-web` | Stubs | wasm-bindgen `Engine` handle with load_map / set_angle / screenshot, all `Err("not implemented")` for now |

## What's deliberately skipped

- **QC interpreter** — vanilla Quake QC VM is not embedded. Server-side
  spawning is native; the engine is a *client* for live play (server
  runs QC remotely); HUD is built natively, not via CSQC.
- **Runtime plugin loader** — crate boundary plays that role instead.

See `fteqw/.claude/notes/rust_port_plan.md` for the full rationale.

## Project conventions (don't break these)

These are encoded in `.claude/notes/` (inside `fteqw/`) and in the
parent's auto-memory. The new session will see them; quick recap:

1. **All deps in `[workspace.dependencies]`** (root `Cargo.toml`).
   Crates reference them with `{ workspace = true }` only. Don't
   add a fresh `foo = "x.y"` directly in a crate; declare in
   workspace first.
2. **Minimum features per dep.** Override `default-features = false`
   when reasonable; only enable what's actually called. Crate-local
   `features = [...]` extensions are fine when context-specific
   (see `web-sys` in `bins/qworld-web/Cargo.toml`).
3. **Lints**: workspace-level `[workspace.lints.clippy]` enables
   pedantic with a sensible allow-list. Every crate opts in via
   `[lints] workspace = true`. CI denies warnings
   (`cargo clippy -- -D warnings`).
4. **Modern stack only**: edition 2024, latest stable Rust, latest
   stable major crate versions (thiserror 2 over 1, etc.). No
   32-bit fallback paths.
5. **Tests**: add unit tests for every parser/decoder so regressions
   show up immediately. Synthetic fixtures (build a fake file in
   memory) preferred over committing binary blobs.

## Next slice (recommended)

Steps 1-5 from the original phasing plan are now done. End-to-end
`qworld render <map.bsp> --out shot.png` is working: produces an
isometric overview PNG of any vanilla Q1 BSP with per-face deterministic
colors (verified against dm3 and povdmm4).

Branching options for the next slice:

1. **Texture upload + sampling** — decode miptex levels, expose
   palette-converted RGBA textures to the renderer, switch the WGSL
   shader from per-vertex color to sampled texture + UV from texinfo
   projection.
2. **Lightmap upload** — read `face.lightofs` per-face, compute
   surface extents from texinfo + face verts, pack into an atlas,
   modulate fragment color.
3. **Camera input + windowed mode** — winit surface, mouse/keyboard
   to orbit, replace the fixed overview camera with a flycam. Needed
   before live demo playback.
4. **Demo playback** — extend `qworld-demo` to fully parse QWD/MVD
   message streams, drive a client-side entity state, render entities
   alongside the world geometry.
5. **Net stack** — netchan transmit/process for live server
   connection; that unblocks the "play on a remote QW server" use case.

After windowed mode + texturing, the engine becomes visibly usable.

## Where to read next

- `rust_port/README.md` — status table, dep choices, roadmap
- `fteqw/.claude/notes/rust_port_plan.md` — design rationale, use cases
- `fteqw/.claude/notes/slim_plan.md` — what the slim FTE config has,
  drives what the Rust client must replicate
- `fteqw/.claude/notes/build_configurability.md` — FTE inventory
  (source of truth for what each Quake macro/feature does)

## Current git state

- Branch: `slim` (still — the Rust port work is uncommitted alongside
  the slim FTE deletions, which are committed)
- Last commit: `592257457 remove quakec`
- Working tree has all of `rust_port/` plus a few in-progress
  modifications. Run `git status` to see, commit when ready.

## Memory pointers

When the new session opens with cwd `/home/vikpe/dev/slipgate/`, its
auto-memory (under `.claude/projects/-home-vikpe-dev-slipgate/memory/`)
already includes the relevant entries:

- `project_rust_quake_client.md` — long-term goal + Phase 2 scaffold
  status
- `quake_world_engine_requirements.md` — hard constraints
- `feedback_modern_stack.md`, `feedback_slim_workflow.md`,
  `feedback_delete_criteria.md` — preferences
