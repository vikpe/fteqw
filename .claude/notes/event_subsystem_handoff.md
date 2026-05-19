---
name: event-subsystem-handoff
description: "Current state of the hub demo-event subsystem after the May 2026 strip-down. Read this before continuing the rewrite described in [[demo-event-redesign]]."
metadata:
  type: project
---

# Hub demo-event subsystem — handoff (post-strip)

Cross-machine handoff. As of 2026-05-19 the entire event subsystem
has been reduced to a no-op stub in preparation for a clean rewrite
per [[demo-event-redesign]]. Read that note for the target design;
this note describes the **current state** so the next session can
pick up without re-deriving it.

## Branch / commit state

- Branch: `newtube`
- All described changes are **uncommitted** on the source machine.
  The new machine needs the working tree synced (commit + pull, or
  rsync) before continuing. If the changes did not arrive, the
  rewrite needs to redo the stub steps below first.

## What's stubbed

`engine/client/cl_hub_demo_event.{c,h}` is now ~120 lines total:

- `cl_hub_demo_event.h` — exports the public hook signatures and the
  three `HDE_KIND_FLAG_TOUCH / _CAPTURE / _DROP` enum values
  (fragstats.c needs them). Everything else from the old header
  (struct definitions, span/player/event globals, internal-ish
  helpers) is gone.
- `cl_hub_demo_event.c` — every public hook is a no-op. Specifically:
  - `Hub_DemoEvent_Init()` → does nothing.
  - `Hub_DemoEvent_IsRecording()` → returns `false` permanently.
  - `Hub_DemoEvent_InMatchTime()` → returns `false` permanently.
  - `Hub_DemoEvent_TimeMs()` → returns 0.
  - All `Hub_DemoEvent_OnFragStats* / OnStatUpdate / OnPlayerinfo /
    OnKtxDrop / OnKtxBackpackPickup / RegisterPlayer` are no-ops.

Because `Hub_DemoEvent_IsRecording()` is permanently false, the
ktxstats playback-capture gate inside
`Hub_KtxStats_OnDemoInfo` always falls through to "skip the
payload" — meaning during normal demo playback, ktxstats accumulates
nothing. The standalone scanner `Hub_KtxStats_Scan()` is unaffected
(it drives the accumulator directly via `ktxstats_append`), and that
is what `getKtxStats` in bindings.cpp uses today.

## What's deleted

These files no longer exist on disk:

- `engine/client/cl_hub_demo_event_internal.h`
- `engine/client/cl_hub_dem_event.c`
- `engine/client/cl_hub_dem_event.h`
- `engine/client/cl_hub_mvd_event.c` (the two functions moved into
  `cl_hub_ktxstats.c` with renamed API)
- `engine/client/cl_hub_mvd_event.h`

`Makefile` was updated to drop `cl_hub_dem_event.o` and
`cl_hub_mvd_event.o`, and add `cl_hub_ktxstats.o`. Two
`Hub_DemEvent_OnFragUpdate(...)` call sites in `cl_parse.c`
(NQ `svc_updatefrags` branches) were also removed since their
declaration was in the deleted `cl_hub_dem_event.h`.

## What survives unchanged (and must keep working)

- **ktxstats** is now self-contained in `engine/client/cl_hub_ktxstats.{c,h}`.
  Public surface:
  - `extern char *hub_ktxstats_json;`
  - `void Hub_KtxStats_Reset(void);`
  - `void Hub_KtxStats_OnDemoInfo(int payload_len, unsigned int is_more);`
  - `int  Hub_KtxStats_Scan(void);`
  Called from `cl_parse.c` (the `mvdhidden_demoinfo 0x0003` branch)
  and from `bindings.cpp`'s `getKtxStats`. Independent of the event
  subsystem; will survive the rewrite untouched.

- **fragstats.c correctness fixes** committed earlier in the same
  branch (spectator filter in `Stats_ExtractName`, 31-char name cap,
  gamedir filter in `Stats_LoadFragFile`, version handshake +
  arg-count validation + line-numbered warnings). These belong to
  the upstream obit parser and have nothing to do with the event
  subsystem.

- **Match-timeline / countdown / total** state in
  `cl_hub_demo_timeline.{c,h}` — independent module.
  `hub_demo_timelimit_ms`, `hub_demo_countdown_ms`,
  `hub_demo_total_ms`, `hub_demo_start_offset_ms`,
  `hub_demo_match_end_ms` are still wired into `getMatchTime` in
  bindings.cpp.

- **Player roster + participants** in `cl_hub_participants.{c,h}` —
  independent module, still alive.

- **Weapon dictionary** served from `getDemoEvents` reads
  `fragstats.weapontotals[]` directly. Still populated.

## What bindings.cpp returns now

`getDemoEvents` returns:

```js
{
    events:  [],          // empty until rewrite lands
    players: [],          // empty until rewrite lands
    spans:   [],          // empty until rewrite lands
    weapons: [/* real */] // populated from fragstats.weapontotals[]
}
```

`getKtxStats` returns the real ktxstats JSON via `Hub_KtxStats_Scan`,
or `null` if the demo carries no `mvdhidden_demoinfo` payload.

The web consumer's response shape is unchanged; only the event
content is empty. Anything that iterates events / players / spans
sees an empty array and no-ops gracefully.

## Where to pick up

The target design is fully written down in [[demo-event-redesign]].
Summary of the rewrite steps:

1. **Phase 1 raw buffers** in a fresh `cl_hub_demo_event.c` (or
   split across files):
   - `death_messages[]` (fragstats obit observations)
   - `deaths[]` (STAT_HEALTH transitions)
   - `tooks[]` (STAT_ITEMS bit gains)
   - `drops[]` (//ktx drop)
   - `backpack_pickups[]` (//ktx bp)
   - `damages[]` (mvdhidden_dmgdone)
   Each buffer is append-only, observation-only, no cross-buffer
   refs during phase 1.

2. **Re-wire the existing hook stubs** (they already have the right
   signatures and are already called from the right places — just
   replace the no-op bodies with append-to-raw-buffer logic).

3. **Phase 2 reconciliation** runs at end of scan. Eight merge
   steps spelled out in the redesign note. Output: TOOK / DEATH /
   MOD_EVENT(ctf_capture) consumer-facing array.

4. **Re-flip `Hub_DemoEvent_IsRecording()`** to actually return
   `true` during a scan. That re-enables the ktxstats
   playback-capture path automatically (no changes needed in
   `cl_hub_ktxstats.c`).

5. **Re-add the scan dispatcher** `Hub_DemoEvent_Scan()` that
   rewinds the demo, drives playback at no-render speed with
   recording on, then runs the reconciliation pass and returns
   event count.

6. **Re-wire `bindings.cpp`**:
   - Restore `getDemoEvents` to call `Hub_DemoEvent_Scan()`,
     iterate the new event types, serialize per-kind fields.
     Same `{events, players, spans, weapons}` shape — fields
     inside `events[]` will differ.
   - The `cls.state = ca_active` and `TP_ReloadCurrentLocs()`
     dance from the old impl needs to come back for location
     name resolution.

## Constraints

- **Do not relax the "sure data only" principle** in phase 1.
  Every cell in every raw buffer must be derived from an
  observation in that single frame. No deferred refresh, no
  patch-in-place. Gap-filling happens in phase 2.
- **Web target only.** `FTE_TARGET=web`. Build with
  `make -j$(nproc) gl-rel LINK_EZHUD=1 LINK_OPENSSL=1` from
  `engine/`. emsdk env must be sourced first
  (`source ~/emsdk/emsdk_env.sh` on the source machine).
- **Slipgate side not yet touched.** When event shape changes,
  the slipgate's log.parse + demo analytics will need updating
  in parallel — see [[event-output-sync]].

## Plan file (session-local, may not follow)

`/home/vikpe/.claude/plans/witty-plotting-bee.md` on the source
machine contains the FTE-vs-ezQuake fragstats comparison from
earlier in the same session. That file lives in `$HOME`, not in
the repo, and probably does not travel to the new machine. The
useful content from it has been distilled into the fragstats fixes
already committed in `engine/client/fragstats.c` and into this note;
the plan file itself is not load-bearing.
