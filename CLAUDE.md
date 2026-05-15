# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## General coding standards

- Never read or reference code in `.bak` directories — treat it as if it doesn't exist.
- Always match the style and conventions already present in the codebase.
- Code must read from top to bottom: public API first, then private helpers/types.
- Always prefix boolean variables and fields with a word that makes them explicitly boolean: `is_`, `has_`, `was_`, `should_`, `can_`, `with_`, etc. For example: `is_first` not `first`, `has_cache` not `cache`, `is_active` not `active`.
- Variables holding counts, should be named x_count, example "user_count"

## Output

- Never express emotions.
- Answer briefly and objectively.
- If unsure, say so. Never guess.
- Drop: filler (just/really/basically/actually/simply), pleasantries (sure/certainly/of course/happy to), hedging. Fragments OK. Short synonyms (big not extensive, fix not "implement a solution for"). Technical terms exact. Code blocks unchanged. Errors quoted exact.
  - Pattern: [thing] [action] [reason]. [next step]
  - Not: "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by..."
  - Yes: "Bug in auth middleware. Token expiry check use < not <=. Fix:"

- No em dashes, smart quotes, or Unicode. ASCII only.

## Scope: web target only

**This project only targets the web (emscripten/wasm) build.** Native Linux, Windows, macOS, Direct3D, Vulkan, SDL, and software-renderer builds are out of scope for every session.

- Do not suggest, test, or validate against non-web targets.
- Do not propose changes that only make sense for native builds.
- When editing shared code (e.g. `engine/client/`, `engine/common/`, `plugins/`), verify only the web build.
- Skip Windows/D3D/Vulkan/SDL code paths unless they share code with the web path.

## Project Overview

FTEQW is an advanced Quake engine. This fork ships it as a wasm module embedded in a web app. Upstream FTEQW supports many backends; here, only the GL/WebGL path compiled via emscripten matters.

## Build Commands

The user has `FTE_TARGET=web` set as a persistent shell env var (`set -gx FTE_TARGET web` in fish), so `gl-rel` builds the web target by default. All builds run from `engine/`.

```bash
cd engine

# Release build (the standard invocation)
make -j$(nproc) gl-rel LINK_EZHUD=1 LINK_OPENSSL=1

# Debug build
make -j$(nproc) gl-dbg LINK_EZHUD=1 LINK_OPENSSL=1

# Build emscripten-side dependencies once (libs-*)
make makelibs
```

`LINK_EZHUD=1` is required - without it the web link fails with `undefined symbol: Plug_EZHud_Init` because the ezhud plugin gets statically linked into the wasm. `LINK_OPENSSL=1` enables TLS.

Output: `engine/release/ftewebgl.js` + `engine/release/ftewebgl.wasm` (or `engine/debug/` for `-dbg`).

## Architecture

### Source layout

- `engine/client/` — Client-side: demo playback, entity parsing, input, HUD, menus, console
- `engine/server/` — Server-side: game logic, physics, entity/player management, networking
- `engine/common/` — Shared: filesystem (`fs.c`), networking (`net_*.c`), QuakeC VM (`pr_*.c`), cvars/commands, math
- `engine/qclib/` — QuakeC compiler (`qcc_pr_comp.c`) and runtime (`pr_exec.c`), decompiler
- `engine/gl/` — OpenGL renderer (backend, shaders, model loading, fonts, heightmaps)
- `engine/d3d/` — Direct3D 8/9/11 renderers
- `engine/vk/` — Vulkan renderer
- `engine/web/` — Emscripten/browser platform: `ftejslib.js` (JS glue, 50KB), `prejs.js`, `bindings.cpp`, `sys_web.c`, `gl_vidweb.c`
- `engine/shaders/` — GLSL/HLSL shader source
- `plugins/` — Optional plugins (physics engines, VR, browser embedding, voice codecs, game-specific support)
- `fteqtv/` — QTV proxy server for demo streaming
- `quakec/` — QuakeC game code and sample mods
- `specs/` — Advanced documentation (CSQC API, extensions, shader system, etc.)

### Key design patterns

- **Renderer abstraction**: Rendering backends (GL/D3D/VK/SW) are swappable; common interface in `engine/gl/` headers
- **Plugin system**: Optional features loaded as shared libraries at runtime via `engine/common/plugin.c`
- **QuakeC VM**: Integrated compiler and runtime; `engine/qclib/` handles both compile-time (`qcc_`) and runtime (`pr_`)
- **Protocol multiplexing**: Single codebase handles QW, NQ Q1/Q2/Q3, HL protocols via conditional paths in `engine/common/`

### Feature configuration

- `engine/common/config_fteqw.h` — Master feature enable/disable flags (1000+ lines)
- `engine/common/config_*.h` — Variant configs (minimal, nocompat, freecs)
- Feature flags flow into Makefile conditionals; no separate configure step needed

## CI/CD

GitHub Actions (`.github/workflows/main.yml`) currently only runs the **web (Emscripten) build** — linux64, win32, win64, and macOS targets are commented out. Uses emscripten 2.0.12, caches `engine/libs-*` keyed on library versions from the Makefile.
