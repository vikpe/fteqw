# FTEQW build/configurability inventory

Reference for planning a "slim FTE" web build by stripping unused
functionality. Scope is the emscripten/wasm target only; native/D3D/Vulkan/
SDL paths are ignored per `engine/CLAUDE.md`.

Descriptive (what exists today), not prescriptive.

---

## 1. Build targets

Defined in `engine/Makefile`. Web targets are the only ones in scope.

### Web targets (in scope)
- `web-rel` — full GL client (client+server merged, emscripten link)
- `webcl-rel` — client-only GL build (smaller, no SV code)
- `web-dbg` — debug GL build (`-O0 -g4`, SAFE_HEAP, ASSERTIONS)

Output: `engine/release/ftewebgl.{js,wasm}` (or `engine/debug/...`).
Release builds are auto-gzipped.

### Native targets (out of scope, listed for awareness)
- Client: `gl-rel`, `glcl-rel`, `mingl-rel`, `vk-rel`, `vkcl-rel`,
  `m-rel`, `mcl-rel`, `d3d-rel`, `d3dcl-rel`
- Server: `sv-rel`
- Tools: `qcc-rel`, `qccgui-rel`, `iqmtool-rel`, `imgtool-rel`,
  `master-rel`, `qtv-rel`
- Android: `droid-rel`, `droid-opt`, `droid-dbg`
- Plugins: `plugins-rel`, `plugins-dbg`
- Misc: `makelibs` (builds emscripten-side deps), `utils`

---

## 2. Build flags (env/CLI)

Selected via `make TARGET FLAG=1`. Configured in `engine/Makefile` and
gated by config-header preprocessor pass.

| Flag | Purpose | Web relevance |
|---|---|---|
| `FTE_TARGET=web` | Selects emscripten toolchain (`emcc`, `em++`, `emar`) and `-DFTE_TARGET_WEB`. User has it persistent in fish. | required |
| `LINK_EZHUD=1` | Statically link ezhud plugin into wasm. | required for web (link fails without it) |
| `LINK_OPENSSL=1` | Statically link OpenSSL for TLS. | optional |
| `LINK_QUAKE3` | Static-link Q3 plugin instead of dlopen. | conditional |
| `LINK_JPEG` | Static libjpeg. | force-disabled on web (browser decodes) |
| `LINK_PNG` | Static libpng. | force-disabled on web |
| `LINK_ZLIB` | Static zlib. | conditional |
| `LINK_FREETYPE` | Static freetype. | force-disabled on web |
| `LINK_VORBISFILE` | Static vorbisfile. | force-disabled on web |
| `LINK_ODE` | Static ODE physics. | conditional |
| `FTE_CONFIG=<name>` | Selects which `config_<name>.h` to use. Defaults to `fteqw`. | drives the entire feature surface |

Standard web release invocation per `CLAUDE.md`:
```
make -j$(nproc) gl-rel LINK_EZHUD=1 LINK_OPENSSL=1
```
(With `FTE_TARGET=web` exported, `gl-rel` resolves to the web client.)

Emscripten link flags worth knowing (set in Makefile around the web
targets):
- `ASMJS_MEMORY=268435456` (256MB heap; can go up to 2GB)
- `-s MAX_WEBGL_VERSION=2`, `-s ALLOW_MEMORY_GROWTH=1`,
  `-s NO_FILESYSTEM=1`
- `-DOMIT_QCC` (no QC compiler in wasm), `-DGL_STATIC`

---

## 3. Config-header variants

The feature surface is driven by `#define`/`#undef` in
`engine/common/config_<name>.h`. The Makefile preprocesses this header
to derive both compile defines and the LINK_* set.

Files present:
- `config_fteqw.h` — default, everything on
- `config_fteqw_noweb.h` — fteqw minus TCP/HTTPSV/FTP/ICE/SUBSERVERS/SSL backends
- `config_minimal.h` — already-slim baseline (see below)
- `config_nocompat.h` — total-conversion mods, breaks vanilla compatibility
- `config_freecs.h` — FreeCS branding/config
- `config_wastes.h` — The Wastes mod branding/config

`config_minimal.h` is the closest existing template to a slim web build.
Its on-by-default set (verified by reading the file):
- Renderers: GLQUAKE (others undef'd as appropriate)
- Particles: PSET_CLASSIC only
- Filesystem: PACKAGE_PK3, PACKAGE_Q1PAK, AVAIL_ZLIB, PACKAGE_TEXWAD
- Maps: Q1BSPS only
- Models: SPRMODELS, MD1MODELS, MD3MODELS
- Images: TGA, LMP, PNG (+ AVAIL_PNGLIB)
- Game support: only the QW baseline; CSQC, MENU_DAT, VM_Q1,
  Q2/Q3/HEXEN2/HLCLIENT/HLSERVER all off
- Networking: HAVE_PACKET, HAVE_HTTPSV, NETPREPARSE — no TCP, no
  WEBCLIENT, no CL_MASTER, no PACKAGEMANAGER
- Audio: AVAIL_DSOUND (native-only; web overrides) — no OGG/MP3/voice/
  jukebox/CD
- QW essentials: QUAKESTATS, QUAKEHUD, QWSKINS
- Misc: MULTITHREAD, LOADERTHREAD, NOQCDESCRIPTIONS=2

It also passes `-Os` and disables OPUS/SPEEX/VORBISFILE/BOTLIB via the
`COMPILE_OPTS` section.

---

## 4. Games / protocols / formats

### Games (gated by macro)
| Game | Macro(s) | Notes |
|---|---|---|
| QuakeWorld | always on (baseline) | core protocol, ver 28 |
| NetQuake (Q1 vanilla) | `NQPROT` | original protocol |
| Quake 2 | `Q2CLIENT`, `Q2SERVER` | protocol 31-36 (Q2Pro/R1Q2 variants) |
| Quake 3 | `Q3CLIENT`, `Q3SERVER` (+ `AVAIL_BOTLIB`) | served via `plugins/quake3/` (loadable or LINK_QUAKE3) |
| Hexen 2 | `HEXEN2` | extended stats via `PEXT_HEXEN2` |
| Half-Life | `HLCLIENT 6|7`, `HLSERVER 138|140` | commented in default config |

### Protocols
QW, NQ, Q2 (multi-variant), Q3, plus FTE extensions (`PEXT_*` flags in
`engine/common/protocol.h`) and EzQuake/mvdsv compat
(`PROTOCOL_VERSION_EZQUAKE1`, `EZPEXT1_*`). `NETPREPARSE` lets one
server speak NQ+QW simultaneously.

### Map formats
Q1 BSP (29 + prerelease + qtest), Q1 extended (2PSB, BSP2, Q64),
HL BSP (30), Q2 BSP (38/69 + variants), Q3 BSP (46, RTCW 47, qfusion
RBSP), terrain heightmaps, BSPX extensions. Gated by
`Q1BSPS`/`Q2BSPS`/`Q3BSPS`/`RFBSPS`/`TERRAIN`.

### Model formats
SPR, MD1, MD2, SP2, MD3, MD5, IQM, PSK, HL MDL, DPM, Zymotic, MDX
(Kingpin), OBJ, glTF. Each is independently gated (`SPRMODELS`,
`MD1MODELS`, etc.).

### Image formats
TGA, LMP, PNG, JPG, GIF, BMP, PCX, DDS, KTX, PKM, ASTC, PBM, PSD, XCF,
HDR, EXR, BLP. Plus software decompressors for ETC2/S3TC/RGTC/BPTC/
ASTC. Gated by `IMAGEFMT_*` and `DECOMPRESS_*`.

### Audio formats
WAV (implicit), Ogg Vorbis (`AVAIL_OGGVORBIS`), Opus (`HAVE_OPUS`),
Speex (`HAVE_SPEEX`), MP3 (`AVAIL_MP3_ACM`, Windows-only), CIN/ROQ
video (`HAVE_MEDIA_DECODER`), CD audio (`HAVE_CDPLAYER`).

### Packages
PK3/ZIP (`PACKAGE_PK3`), PAK Q1/Q2 (`PACKAGE_Q1PAK`), DZIP
(`PACKAGE_DZIP`), Doom WAD (`PACKAGE_DOOMWAD`), TexWAD
(`PACKAGE_TEXWAD`). Plugins add MPQ (Blizzard), VPK (HL2).

### QuakeC dialects
SSQC (server-side), CSQC (`CSQC_DAT`), Menu-QC (`MENU_DAT`) or native
menu (`MENU_NATIVECODE`), Q1QVM bytecode (`VM_Q1`), optional Lua
(`VM_LUA`).

---

## 5. Renderer backends

| Backend | Macro | Web? |
|---|---|---|
| OpenGL / WebGL 2 | `GLQUAKE` | yes (only one) |
| Vulkan | `VKQUAKE` | no |
| D3D 8/9/11 | `D3D8QUAKE`, `D3D9QUAKE`, `D3D11QUAKE` | no |
| Software | `SWQUAKE` | no (DOS target) |
| Headless | `HEADLESSQUAKE` | no-op |
| Wayland | `WAYLANDQUAKE` | linux only |

Web link object set: `GLCL_OBJS = GL_OBJS + D3DGL_OBJS + BOTLIB_OBJS +
GLQUAKE_OBJS + gl_vidweb.o + cd_null.o`.

Web-specific files under `engine/web/`:
- `sys_web.c` — platform abstraction (errors, console, timer)
- `fs_web.c` — JS-backed filesystem
- `gl_vidweb.c` — WebGL init / canvas
- `bindings.cpp` — emscripten C++ bindings
- `ftejslib.{js,h}` — 58-API JS library (websockets, WebRTC, WebXR,
  audio, input)
- `prejs.js` — preload script
- `fteshell.html` — HTML container template
- `fte_pwa.json`, `fte_pwa_sw.js` — PWA manifest + service worker

---

## 6. Plugins

Located in `plugins/`. Verified list (24 dirs + root files):

| Plugin | Purpose | Web build? |
|---|---|---|
| `ezhud` | Advanced HUD system (ezQuake-style, with editor). | yes — must be statically linked (LINK_EZHUD=1) |
| `ezscript` | Scripting/automation system. | likely yes |
| `hud` | Classic Quake statusbar (ui_sbar.c). | likely yes |
| `quake3` | Q3 client/protocol implementation. | optional (LINK_QUAKE3) |
| `models` | Extra model formats: glTF, Draco, IQM export. | C++ heavy; check |
| `botlib` | Q3 botlib glue. | with Q3 only |
| `bullet` | Bullet physics (C++). | native-only typically |
| `avplug` | FFmpeg audio/video codecs. | native-only |
| `cef` | Chromium Embedded Framework (in-game browser). | native-only |
| `berkelium` | Legacy alternative to CEF. | native-only |
| `hl2` | HL2 VPK + VTF format. | filesystem plugin |
| `mpq` | Blizzard MPQ archive support. | filesystem plugin |
| `cod` | Call of Duty BSP support. | native-only typically |
| `winamp` | MP3/media player integration. | native-only (Windows) |
| `irc` | IRC client. | native-only |
| `jabber` | XMPP/Jingle chat. | native-only |
| `emailnot` | POP3/IMAP email notifications. | native-only |
| `serverb` | Server browser / master server client. | likely yes |
| `xsv` | X server virtual net iface. | native-only |
| `qi` | QI protocol encoding. | unknown |
| `namemaker` | Name generation utility. | unknown |
| `spaceinv` | Space Invaders demo. | sample |
| `terrorgen` | Terrain generation utility. | unknown |
| `openxr.c` (root) | OpenXR / WebXR support. | yes (WebXR) |
| `net_ssl_openssl.c` (root) | OpenSSL backend (not statically linked by default; GPL3 concerns). | optional |

Plugins are usually dlopen'd; for web they must be statically linked or
omitted entirely.

---

## 7. Major engine features

Grouped by subsystem. Each is independently gateable.

**Rendering**
- Particles: `PSET_CLASSIC` (Quake-classic), `PSET_SCRIPT` (DP
  effectinfo-compatible)
- Lighting: `RTLIGHTS`, `RUNTIMELIGHTING` (.lit generation)
- HUD: `QUAKEHUD` (vanilla), `CSQC_DAT` (CSQC-driven), ezhud (plugin)
- Menu: `MENU_DAT` (QC), `MENU_NATIVECODE` (DLL), `NOBUILTINMENUS`
- Fonts: freetype (native), bitmap fallback

**Networking**
- `HAVE_PACKET` — basic UDP
- `HAVE_TCP` — TCP sockets (force-off on web; websockets used instead)
- `HAVE_GNUTLS` / `HAVE_WINSSPI` — native TLS backends
- `WEBCLIENT` — HTTP downloads / URI fetches
- `HAVE_HTTPSV` — embedded HTTP/WS server
- `FTPSERVER` — FTP server mode
- `TCPCONNECT` — game-over-TCP (Qizmo compat)
- `IRCCONNECT` — game-over-IRC
- `SUPPORT_ICE` — NAT traversal (WebRTC-ish)
- `CL_MASTER` — server browser
- `PACKAGEMANAGER` — package install UI (depends on WEBCLIENT)
- `HUFFNETWORK` — Huffman packet compression
- `SUBSERVERS` — MMO-style server-of-servers

**Demos / replay (client)**
- `cl_demo.c` — playback (NQ/QWD/MVD)
- `cl_hub.c` family — advanced timeline/event tracking, KTX stats
- `cl_cam.c` — chase/spectator camera
- `fragstats.c` — frag tracking

**Server-side (excluded from `webcl-rel`)**
- `MVD_RECORDING`, `sv_mvd.c` — MVD demo recording / QTV streaming
- `SAVEDGAMES` — save/load
- `sv_master.c` — master server integration
- `sv_phys.c`, `sv_move.c` — physics/movement
- `sv_chat.c`, `sv_ccmds.c` — server commands
- `pr_cmds.c` — server QC builtins
- `SVRANKING` — legacy ranking
- `ENGINE_ROUTING` — engine-provided routing
- `SVCHAT`, `SV_MASTER`, `QUAKESPYAPI` — legacy

**Audio**
- Drivers: `AVAIL_OPENAL`, `AVAIL_WASAPI`, `AVAIL_DSOUND`, mixer
  fallback
- Codecs: WAV, Opus, Speex, Vorbis, MP3, ROQ/CIN, CD, jukebox,
  speech-to-text
- `VOICECHAT` — in-game voice

**Physics**
- `USE_INTERNAL_BULLET`, `USE_INTERNAL_ODE` — static-link physics
- Otherwise loaded as plugin

**Filesystem / packages**
- See section 4

**Misc**
- `PLUGINS` — runtime plugin loader
- `TEXTEDITOR` — in-engine text editor
- `USE_SQLITE` — SQLite backend
- `MULTITHREAD`, `LOADERTHREAD` — threading
- `SIDEVIEWS=4`, `MAX_SPLITS=4` — splitscreen up to 4 players
- `IPLOG` — IP address tracking
- `USEAREAGRID` — broad-phase collision optim

**Cross-dependencies (notable)**
- QTV streaming requires MVD_RECORDING
- PACKAGEMANAGER requires WEBCLIENT
- CSQC_DAT pairs with ezhud
- AVAIL_BOTLIB requires Q3CLIENT/Q3SERVER
- Q1QVM (`VM_Q1`) required to run ktx mod
