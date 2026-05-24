# Slim FTE plan (Phase 1)

Strip the fteqw web build down to only what quake.world needs.
Reference of what currently exists: [build_configurability.md](build_configurability.md).
Future Rust rewrite: [rust_port_plan.md](rust_port_plan.md).

## Context

The current wasm carries the full FTE feature surface (every game,
every format, every protocol). Quake.world only needs QuakeWorld. Two
wins from slimming:

1. **Smaller wasm** — faster page load on quake.world.
2. **Concrete spec for the Rust port** — whatever survives stripping
   defines what the Rust client must replicate.

Hard constraints (see project memory):

- **Local in-process server required.** Map previews and screenshot
  capture both need to spawn a client on a map, which requires a
  local server. `CLIENTONLY` stays undefined. Build target stays
  `gl-rel` (client+server merged web), not `webcl-rel`.
- **Web target only** per `engine/CLAUDE.md` scope. Streambot use
  case is unix-native and belongs to the Rust port, not Phase 1.

## Approach

Author `engine/common/config_qwslim.h` by copying `config_minimal.h`
and enabling the specific features QW needs. Build with:

```
make -j$(nproc) gl-rel LINK_EZHUD=1 FTE_CONFIG=qwslim
```

(`FTE_TARGET=web` is in the user's persistent fish env.)

The Makefile already supports `FTE_CONFIG=<name>` to select which
`config_<name>.h` to preprocess — no Makefile changes needed.

## Per-category decisions

Defaults below are proposals; **OPEN** items need a decision before
the header can be authored.

### Games
- Keep: QuakeWorld baseline (always on)
- Drop: `NQPROT`, `Q2CLIENT`, `Q2SERVER`, `Q3CLIENT`, `Q3SERVER`,
  `HEXEN2`, `HLCLIENT`, `HLSERVER`, `AVAIL_BOTLIB`

### Maps
- Keep: `Q1BSPS`
- **OPEN**: BSP2 (some modern QW maps use it)
- Drop: `Q2BSPS`, `Q3BSPS`, `RFBSPS`, `TERRAIN`, `DOOMWADS`,
  `MAP_PROC`

### Models
- Keep: `SPRMODELS`, `MD1MODELS`
- **OPEN**: `MD3MODELS`
- Drop: MD2, MD5, IQM, PSK, HL MDL, Zymotic, DPM, MDX, OBJ, glTF

### Images
- Keep: `IMAGEFMT_TGA`, `IMAGEFMT_LMP`, `IMAGEFMT_PNG`,
  `IMAGEFMT_PCX` (QW player skins are PCX), `PACKAGE_TEXWAD`,
  `AVAIL_PNGLIB`
- **OPEN**: `IMAGEFMT_JPG` (Q3-style skyboxes)
- Drop: DDS, KTX, PKM, ASTC, PBM, PSD, XCF, HDR, EXR, GIF, BMP, BLP
- Drop all `DECOMPRESS_*` (GPU formats, irrelevant on WebGL2)

### Audio
- Keep: WAV (implicit), web audio via JS
- **OPEN**: `AVAIL_OGGVORBIS` (in-game music)
- **OPEN**: `HAVE_OPUS` + `VOICECHAT`
- Drop: MP3, Speex, CD, jukebox, media decoder, speech-to-text

### Networking
- Keep: `HAVE_PACKET`, `HAVE_HTTPSV` (already in minimal)
- Drop: `HAVE_TCP`, `FTPSERVER`, `TCPCONNECT`, `IRCCONNECT`,
  `SUPPORT_ICE`, `HUFFNETWORK`, `SUBSERVERS`
- **OPEN**: `WEBCLIENT` (HTTP downloads from inside the engine)
- **OPEN**: `CL_MASTER` (server browser — likely the web app
  provides this)
- **OPEN**: `PACKAGEMANAGER` (depends on WEBCLIENT)
- **OPEN**: Live remote-server connection from the web build — needed
  for "watch live game" or preview/demo-playback only?

### Server-side
**Keep the server.** Web build hosts a local in-process server for
map preview / screenshot spawning.

Keep (required for spawning on a map):
- Core server: `sv_main.c`, `sv_init.c`, `sv_ents.c`, `sv_send.c`,
  `sv_user.c`, `sv_phys.c`, `sv_move.c`, `sv_world.c`,
  `sv_ccmds.c` — not separately gated, come with any non-`CLIENTONLY`
  build
- QC interpreter (`engine/qclib/pr_exec.c` etc.) — required for
  worldspawn, entity spawning, physics callbacks
- **OPEN**: `VM_Q1` — KTX ships as compiled QVM bytecode. Keep if
  the local server should run KTX serverside QC for realistic
  previews.

Drop (legacy / not preview-related):
- `MVD_RECORDING`, `SAVEDGAMES`, `SV_MASTER`, `SVRANKING`,
  `ENGINE_ROUTING`, `SUBSERVERS`, `FTPSERVER`, `SVCHAT`,
  `QUAKESPYAPI`, `IPLOG`

### QuakeC
- **OPEN**: `CSQC_DAT` — modern QW servers (KTX) use CSQC for HUDs
- **OPEN**: `MENU_DAT` vs `NOBUILTINMENUS` (web shell + ezhud handle
  UI)
- **OPEN**: `VM_Q1` — see Server-side
- Drop: `VM_LUA`, `MENU_NATIVECODE`

### Packages / filesystem
- Keep: `PACKAGE_PK3`, `PACKAGE_Q1PAK`, `AVAIL_ZLIB`
- Drop: `PACKAGE_DZIP`, `PACKAGE_DOOMWAD`, `AVAIL_XZDEC`,
  `AVAIL_BZLIB`, `USE_SQLITE`

### Renderer
- Keep: `GLQUAKE`
- Drop: `D3D*QUAKE`, `VKQUAKE`, `SWQUAKE`, `HEADLESSQUAKE`,
  `WAYLANDQUAKE`

### Plugins
- Keep: `ezhud` (statically linked via `LINK_EZHUD=1`; required for
  web link to succeed), `ezscript` (kept for now — quake.world may
  ship user automation scripts)
- Drop: everything else (already removed: avplug, cef, berkelium,
  hl2, mpq, cod, winamp, irc, jabber, emailnot, xsv, bullet,
  spaceinv, terrorgen, namemaker, qi, openxr.c, hud, serverb,
  botlib, quake3, models)

For the CLI demo->mpeg use case, the Rust port pipes raw RGBA from
wgpu to a `ffmpeg` subprocess; it does not need FTE's avplug as
reference. See [rust_port_plan.md](rust_port_plan.md).

**Note when deciding deletions:** evaluate against long-term goals
(web build + Rust port use cases), not just current web-build
linkage. A native-only plugin that no use case ever needs — *or
where the Rust port has a better alternative* — can go.

### Misc
- Keep: `MULTITHREAD`, `LOADERTHREAD`, `QUAKESTATS`, `QUAKEHUD`,
  `QWSKINS`, `NOQCDESCRIPTIONS 2`
- Drop: `TEXTEDITOR`, `PLUGINS` (runtime loader), `SIDEVIEWS`,
  `MAX_SPLITS`, `IPLOG`, `SVCHAT`, `QUAKESPYAPI`, `USE_SQLITE`
- **OPEN**: `USEAREAGRID` (collision optim; harmless, likely keep)

## Open decisions blocking final authoring

1. **CSQC** — keep `CSQC_DAT`? (KTX HUDs likely need it)
2. **VM_Q1 (QVM)** — keep so the local server can run KTX QVM mods?
3. **Menu** — `NOBUILTINMENUS` or keep `MENU_DAT`?
4. **Voice chat** — `HAVE_OPUS` + `VOICECHAT` in or out?
5. **Music** — `AVAIL_OGGVORBIS` in or out?
6. **Server browser / downloads** — `CL_MASTER`, `WEBCLIENT`,
   `PACKAGEMANAGER` provided by web app or engine?
7. **Modern QW asset formats** — keep BSP2, MD3, JPG?
8. **Live-server connection** — web build joins live servers, or
   preview / demo playback only?

## Implementation steps (after decisions land)

1. Copy `engine/common/config_minimal.h` →
   `engine/common/config_qwslim.h`; update branding macros if
   desired.
2. Apply the per-category decisions: flip `//#define` ↔ `#define` ↔
   `#undef` for each toggle.
3. Update the `COMPILE_OPTS` block at the bottom for static-link
   flags (`-DLINK_PNG` if `AVAIL_PNGLIB`; `-DNO_VORBISFILE`, etc).
4. Build: `make -j$(nproc) gl-rel LINK_EZHUD=1 FTE_CONFIG=qwslim`.
5. Sync to slipgate via
   `.claude/scripts/sync-fte-to-slipgate.sh` (per [workflow.md](workflow.md)).
6. Measure wasm size delta vs baseline.
7. Smoke-test in the slipgate web app: load a QW demo, preview a map,
   confirm ezhud renders, check console for missing-feature errors.

## Verification

End-to-end checks once built:

- Load the slipgate web app in the browser.
- Spawn-on-map preview works (background server boots, client renders
  the level).
- Demo playback works (QWD and MVD).
- ezhud renders correctly.
- No "missing feature" / "unknown" / "skipped" log lines in devtools
  console. If found, re-enable the smallest unit covering it and
  rebuild.
- Document the wasm size delta vs baseline.
