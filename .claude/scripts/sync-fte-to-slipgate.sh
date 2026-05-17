#!/usr/bin/env bash
# PostToolUse hook: after a `make gl-rel ... LINK_EZHUD=1 ...` Bash call
# completes, force-copy the web build artifacts into the slipgate web
# project's public/fte/ directory so the website serves the fresh wasm.
#
# Receives the Bash tool input JSON on stdin (tool_name, tool_input.command,
# tool_response.{stdout,stderr,exit_code}). PostToolUse only fires on
# successful tool runs (failures route to PostToolUseFailure), but we still
# gate on the command pattern so non-FTE make calls don't trigger a copy.

set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

# Only fire for FTE web builds or hub_addon CSQC builds. The engine
# pattern requires both gl-rel and LINK_EZHUD=1 in the command; the
# CSQC pattern matches a `make` issued against the hub_addon
# directory (covers `make -C .../hub_addon` and `cd hub_addon && make`).
is_engine_build=0
is_addon_build=0
printf '%s' "$cmd" | grep -qE 'gl-rel.*LINK_EZHUD|LINK_EZHUD.*gl-rel' && is_engine_build=1
printf '%s' "$cmd" | grep -qE 'make.*hub_addon|hub_addon.*make' && is_addon_build=1
if [ $is_engine_build -eq 0 ] && [ $is_addon_build -eq 0 ]; then
    exit 0
fi

SRC_ENGINE=/home/vikpe/dev/fteqw/engine/release
SRC_ADDON=/home/vikpe/dev/fteqw/hub_addon
DST=/home/vikpe/dev/slipgate/web/apps/website/public/fte

# Force-copy. -f drops the destination first, avoiding read-only/holding issues.
[ -f "$SRC_ENGINE/ftewebgl.js"   ] && cp -f "$SRC_ENGINE/ftewebgl.js"   "$DST/" 2>/dev/null
[ -f "$SRC_ENGINE/ftewebgl.wasm" ] && cp -f "$SRC_ENGINE/ftewebgl.wasm" "$DST/" 2>/dev/null
[ -f "$SRC_ADDON/csaddon.dat"    ] && cp -f "$SRC_ADDON/csaddon.dat"    "$DST/" 2>/dev/null

exit 0
