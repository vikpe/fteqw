# FTE web hub build

FTEQW as a wasm module for the slipgate web app. Web target only.

Outputs (synced into `<slipgate>/web/apps/website/public/fte/`):
- `engine/release/ftewebgl.js`
- `engine/release/ftewebgl.wasm`
- `hub_addon/csaddon.dat`

## Dependencies

`fteqcc` and `emsdk` 2.0.12 (CI-pinned, `.github/workflows/main.yml`).

```sh
# fteqcc
curl -o /tmp/fteqcc_linux64.zip https://www.fteqcc.org/dl/fteqcc_linux64.zip
sudo unzip -d /usr/local/bin /tmp/fteqcc_linux64.zip fteqcc64
sudo chmod +x /usr/local/bin/fteqcc64

# emsdk
git clone https://github.com/emscripten-core/emsdk.git ~/emsdk
cd ~/emsdk
./emsdk install 2.0.12
./emsdk activate 2.0.12
```

Source per shell session:

```sh
. ~/emsdk/emsdk_env.sh         # bash/zsh
source ~/emsdk/emsdk_env.fish  # fish

emcc -v                        # 2.0.12
```

## One-shot build

Builds addon + engine, syncs artifacts. Auto-detects `emsdk` in `$EMSDK`, `~/emsdk`, `~/dev/emsdk`, `/opt/emsdk`, `/usr/local/emsdk`.

```sh
./.claude/scripts/sync-fte-to-slipgate.sh build
```

## Manual builds

### Hub addon (CSQC)

```sh
cd hub_addon
FTEQCC=fteqcc64 make clean && FTEQCC=fteqcc64 make
```

### FTE engine (web)

`LINK_EZHUD=1` required (else link fails: `undefined symbol: Plug_EZHud_Init`). `LINK_OPENSSL=1` enables TLS.

```sh
. ~/emsdk/emsdk_env.sh
export FTE_TARGET=web
cd engine
make FTE_TARGET=web makelibs           # first build only
make -j"$(nproc)" gl-rel LINK_EZHUD=1 LINK_OPENSSL=1
```

Fish:
```fish
source ~/emsdk/emsdk_env.fish
set -gx FTE_TARGET web
```
