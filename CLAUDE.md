# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Output

- Never express emotions.
- Answer briefly and objectively.
- If unsure, say so. Never guess.
- No em dashes, smart quotes, or Unicode. ASCII only.
- Drop: filler (just/really/basically/actually/simply), pleasantries (sure/certainly/of course/happy to), hedging. Fragments OK. Short synonyms (big not extensive, fix not "implement a solution for"). Technical terms exact. Code blocks unchanged. Errors quoted exact.
  - Pattern: [thing] [action] [reason]. [next step]
  - Not: "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by..."
  - Yes: "Bug in auth middleware. Token expiry check use < not <=. Fix:"

## Project Overview

FTEQW is an advanced, portable Quake engine ("swiss-army knife" for Quake game development). It supports multiple Quake-family protocols (QW, NQ, Q2, Q3, Hexen2, Half-Life) and multiple rendering backends (OpenGL, Direct3D 8/9/11, Vulkan, software, WebGL).

## Build Commands

All builds are run from the `engine/` directory. No manual configuration needed — the Makefile auto-configures based on target.

```bash
cd engine

# Server (dedicated)
make sv-rel -j4

# Client builds (choose renderer)
make gl-rel -j4       # OpenGL (most common)
make vk-rel -j4       # Vulkan
make m-rel -j4        # Software renderer

# QuakeC compiler
make qcc-rel -j4

# Web/Emscripten
make FTE_TARGET=web gl-rel

# Cross-compile for Windows (from Linux)
make FTE_TARGET=win64 m-rel
make FTE_TARGET=win32 m-rel

# Debug builds (append -dbg instead of -rel)
make gl-dbg -j4

# Build dependencies first (needed for web/cross-compilation)
make FTE_TARGET=web makelibs
```

Output binaries go to `engine/release/` (or `engine/debug/`).

## Running

```bash
engine/release/fteqw.sv -nohome -basedir ~/quake    # Dedicated server
engine/release/fteqw.gl -nohome -basedir ~/quake    # GL client
```

Key flags: `-nohome` (disable home dir), `-basedir $DIR`, `-game $MOD`, `+sv_public 0` (no master server reporting).

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
