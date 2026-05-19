#!/usr/bin/env bash
# Two modes:
#
#  1. Hook mode (default, no args). Reads PostToolUse JSON from stdin
#     (tool_name, tool_input.command, tool_response.*). If the command
#     matches an FTE web build or a hub_addon CSQC build, copies the
#     resulting artifacts into the slipgate web project's public/fte/
#     directory. PostToolUse only fires on successful tool runs.
#
#  2. Build mode (`build` arg). Compiles the hub_addon CSQC progs and
#     the FTE web target from scratch, then syncs. Used when engine
#     sources changed and a fresh ftewebgl.js + ftewebgl.wasm pair is
#     needed - deleting both outputs first guarantees the link step
#     regenerates them together (an asymmetric rebuild that ships a
#     stale .js against a fresh .wasm trips emscripten's
#     'Import #0 env: module is not an object' load failure).

set -u

BASEDIR=/home/vikpe/dev/fteqw
SRC_ENGINE=$BASEDIR/engine/release
SRC_ADDON=$BASEDIR/hub_addon
DST=/home/vikpe/dev/slipgate/web/apps/website/public/fte

sync_artifacts() {
    [ -f "$SRC_ENGINE/ftewebgl.js"   ] && cp -f "$SRC_ENGINE/ftewebgl.js"   "$DST/" 2>/dev/null
    [ -f "$SRC_ENGINE/ftewebgl.wasm" ] && cp -f "$SRC_ENGINE/ftewebgl.wasm" "$DST/" 2>/dev/null
    [ -f "$SRC_ADDON/csaddon.dat"    ] && cp -f "$SRC_ADDON/csaddon.dat"    "$DST/" 2>/dev/null
}

if [ "${1:-}" = "build" ]; then
    set -e

    # CSQC progs first (fast).
    cd "$SRC_ADDON"
    FTEQCC=fteqcc64 make

    # FTE web engine. emsdk env is required for em++; FTE_TARGET=web
    # selects the emscripten build path inside the Makefile.
    export FTE_TARGET=web
    # shellcheck disable=SC1091
    . /home/vikpe/emsdk/emsdk_env.sh > /dev/null 2>&1
    cd "$BASEDIR/engine"
    rm -f release/ftewebgl.js release/ftewebgl.wasm
    make -j"$(nproc)" gl-rel LINK_EZHUD=1 LINK_OPENSSL=1

    sync_artifacts
    exit 0
fi

# Hook mode: read JSON from stdin, match command pattern, copy.
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

# Engine build pattern requires both gl-rel and LINK_EZHUD=1; the addon
# pattern matches a `make` issued against the hub_addon directory
# (covers `make -C .../hub_addon` and `cd hub_addon && make`).
is_engine_build=0
is_addon_build=0
printf '%s' "$cmd" | grep -qE 'gl-rel.*LINK_EZHUD|LINK_EZHUD.*gl-rel' && is_engine_build=1
printf '%s' "$cmd" | grep -qE 'make.*hub_addon|hub_addon.*make' && is_addon_build=1
if [ $is_engine_build -eq 0 ] && [ $is_addon_build -eq 0 ]; then
    exit 0
fi

sync_artifacts
exit 0
