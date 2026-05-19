---
name: demo-event-redesign
description: "Planned refactor of the Hub demo-event types: collapse the flat hub_demo_event_t into per-kind structs, fold rune/item/backpack/flag-touch into TOOK, expose ctf_capture as MOD_EVENT. Internal/external kind split."
metadata:
  type: project
---

# Hub demo event v2 — type redesign

Captured before implementation. The current `hub_demo_event_t`
(`engine/client/cl_hub_demo_event.h`) is a wide flat struct with six
event kinds and many mostly-N/A fields per row. Goal of this redesign:
narrow each kind to the fields it actually uses, collapse the
proliferation of kinds, and keep the consumer-facing surface small.

## Why

- 11 fields x 6 kinds, most cells N/A — see the field applicability
  matrix produced earlier in the session. Cost is paid every event.
- Three flag kinds (`FLAG_TOUCH / FLAG_CAPTURE / FLAG_DROP`) for what
  is effectively two semantics: "took the flag" (a pickup with
  IT_KEY1/2 bit) and "scored" (a discrete event).
- `ITEM_PICKUP` and `BACKPACK_PICKUP` differ only in provenance —
  same target player, same IT_ bit, same origin. Currently a separate
  kind solely because the backpack's source player is interesting.
- Rune pickups already go through `HDE_KIND_ITEM_PICKUP` with the
  IT_SIGIL bit set. The pattern works; flag-touch can follow the
  same trick.

## Background: the IT_ bitmask is unified

From `engine/common/bothdefs.h`:
- weapons: IT_AXE..IT_LIGHTNING (bits 0-7)
- armors / powerups: bits 8-16
- **flags: IT_KEY1 = 1<<17, IT_KEY2 = 1<<18**
- **runes: IT_SIGIL1..4 = 1<<28..1<<31**

Single 32-bit `unsigned int items` field can carry any of them. This
is what lets the TOOK refactor collapse "weapon / armor / powerup /
rune / flag-touch" into one shape.

## Consumer-facing event kinds (output of scan)

| Kind | Means | Key fields |
|---|---|---|
| TOOK | Player picked something up (weapon, armor, powerup, rune, flag) | victim_user_id, items (single IT_* bit), origin, optional backpack_user_id |
| DEATH | A player died | victim_user_id, killer_user_id, weapon_id, victim_items, origin, killer_origin, obit_text |
| MOD_EVENT | Mod-specific discrete event | victim_user_id, sub-kind ("ctf_capture" etc.), origin |

MOD_EVENT carries a `mod_event_kind` enum/string slot. Initial value:
`ctf_capture`. Future: bonus flag returns, gametype-specific scoring
events, etc.

`FLAG_DROP` does NOT become a consumer event — see "internal kinds"
below; drops are an attribution input that resolves backpack
provenance for later TOOKs.

## Two-phase architecture: observe-then-reconcile

The redesign separates the scan into two strict phases. **Phase 1
records only what we are 100% sure of at the moment of observation**,
each signal into its own raw buffer, with no merging, no patching, no
deferred refresh. **Phase 2 runs after all frames have been parsed**
and produces the consumer-facing event array by reconciling the
raw buffers against each other.

This removes the entire "emit-while-still-uncertain" machinery the
current code carries:

- `inflight_origin_indices` deferred-origin refresh on
  `svc_playerinfo` (handles dem_stats-before-dem_all in mvdsv MVDs).
- `fragstats_last_event_index` per-slot back-pointers used by the
  STAT_HEALTH death hook to enrich an already-pushed fragstats event.
- `pending_event_index` for one-sided fragstats obits awaiting a
  later svc_updatefrags delta to fill in the missing side.
- The patch-in-place loop inside `Hub_DemoEvent_OnFragStatsKill`
  that searches recent events for a same-victim or killer-partial
  match and rewrites fields, including the index compaction and
  the per-slot pointer fix-up.

All of those exist because emission and attribution interleave during
the parse. Decoupling them via two phases makes them unnecessary.

### Phase 1 — raw observation buffers

Each signal source has its own append-only buffer. No cross-buffer
references during phase 1. Every row records the time it was
observed (demtime ms) plus only the data directly observed in that
frame.

| Raw buffer | Source | Fields (only what is sure at observation) |
|---|---|---|
| `death_messages[]` | fragstats obit parse (`Stats_Evaluate` -> hub hook) | time, killer_uid (or -1), victim_uid (or -1), weapon_id, obit_text, fftype (frag / suicide / tkill / death / capture / rune) |
| `deaths[]` | STAT_HEALTH > 0 -> <= 0 transition | time, victim_slot, victim_uid, victim_items (cached STAT_ITEMS), victim_origin (from playerstate AFTER the matching svc_playerinfo lands in the same frame — capture at end-of-frame, not at the transition instant) |
| `tooks[]` | STAT_ITEMS single-bit gain | time, picker_slot, picker_uid, items_bit, picker_origin |
| `drops[]` | `//ktx drop` stufftext | time, dropper_slot, dropper_uid, items_bitmask, drop_origin, entnum |
| `backpack_pickups[]` | `//ktx bp` stufftext | time, picker_slot, picker_uid, entnum |
| `damages[]` | `mvdhidden_dmgdone` | time, attacker_uid, target_uid, damage, was_team_damage |

Notes:
- `victim_origin` capture is delayed until end-of-frame so the
  origin reflects the *playerinfo of the dying frame*, not the
  previous frame. End-of-frame in the MVD parser is a single
  well-defined point per packet — no per-event inflight bookkeeping.
- A flag-capture obit lands in `death_messages[]` like any other
  fragstats match. Phase 2 classifies it as `MOD_EVENT(ctf_capture)`
  on the way out — there's no separate `captures[]` buffer.
- `damages[]` is captured as raw data only. Attribution decisions
  happen in phase 2.

### Phase 2 — reconciliation pass

Runs once after the scan loop exits. Each step is a deterministic
merge over the raw buffers.

1. **Match `death_messages` to `deaths`** by victim within a small
   time window (e.g. ±100 ms). The death_message supplies killer_uid,
   weapon_id, obit_text; the death supplies origin, victim_items.
2. **Salvage unmatched `death_messages`** (no matching STAT_HEALTH
   transition observed — POV-only NQ where we couldn't see the
   victim's stats): emit as DEATH with origin = {0,0,0},
   victim_items = 0. Honest "we know it happened, no positional
   data" record.
3. **Salvage unmatched `deaths`** (STAT_HEALTH dropped but no obit
   matched a pattern): emit as DEATH with killer_uid = 0
   (unattributed), weapon_id = 0, obit_text = "". The damages
   buffer is consulted only as a tie-breaker (see step 4) — never
   used to invent a killer.
4. **Damage-based attribution (conservative)**: for an unmatched
   death, if `damages[]` contains exactly one attacker whose
   cumulative damage in the last ~1 s of game time is >= the
   victim's last observed health, accept that attacker as the
   killer. Multiple plausible attackers => unattributed. This
   replaces the removed `killer_items` heuristic in the current
   header (which produced wrong loadouts in overlapping kills);
   the principle is "only attribute when there is exactly one
   candidate."
5. **Pair `drops` with `backpack_pickups`** by entnum (already a
   stable key). Produces `(dropper_uid, items_bitmask, picker_uid,
   pickup_time)` records — one per backpack pickup.
6. **Match `tooks` to `(backpack -> pickup)` records** by picker
   and item bit within the pickup time window. A TOOK whose
   item bit appears in a backpack's bitmask, picked up by the
   same player, gets `backpack_user_id = dropper_uid`. Unmatched
   TOOKs get `backpack_user_id = 0` (ground / spawn pickup).
7. **Classify capture obits**: any `death_messages` row whose
   fftype is flag-capture becomes `MOD_EVENT(ctf_capture)` instead
   of DEATH. Origin from the actor's playerstate cached in the
   matching tooks/deaths window if available, else 0.
8. **Drop unmerged raw rows** that have no consumer output (e.g.
   damages that didn't lead to a death, drops that were never
   picked up by anyone).

The output is the consumer event array: chronologically ordered
TOOK / DEATH / MOD_EVENT records. Existing `hub_demo_players[]`
roster and `hub_demo_spans[]` weapon-hold spans are unchanged in
shape; they're independent of this kind redesign.

## Struct shape (sketch)

Per-kind tagged union, or per-kind arrays. Sketch:

```c
typedef enum {
    HDE_TOOK = 0,
    HDE_DEATH,
    HDE_MOD_EVENT,
} hub_demo_event_kind_t;

typedef enum {
    HDE_MOD_CTF_CAPTURE = 0,
    // future: HDE_MOD_DOM_CAPTURE, HDE_MOD_RA_WIN, etc.
} hub_demo_mod_event_kind_t;

typedef struct {
    int  time_ms;
    int  victim_user_id;        // the picker
    unsigned int items;          // single IT_* bit (weapon/armor/powerup/rune/flag)
    int  backpack_user_id;      // dropper if from a backpack, else 0
    float origin[3];
} hub_demo_took_t;

typedef struct {
    int  time_ms;
    int  victim_user_id;
    int  killer_user_id;        // == victim for suicide; -1 unknown; 0 unattributed
    unsigned int weapon_id;     // fragstats wid (look up in fragstats.weapontotals[])
    unsigned int victim_items;  // STAT_ITEMS at death
    float origin[3];            // victim
    float killer_origin[3];     // killer
    char obit_text[HUB_DEMO_OBIT_BYTES];
} hub_demo_death_t;

typedef struct {
    int  time_ms;
    int  victim_user_id;
    hub_demo_mod_event_kind_t mod_kind;
    float origin[3];
} hub_demo_mod_event_t;

typedef struct {
    hub_demo_event_kind_t kind;
    union {
        hub_demo_took_t       took;
        hub_demo_death_t      death;
        hub_demo_mod_event_t  mod;
    } u;
} hub_demo_event_t;
```

Trade-off: tagged union vs three parallel arrays. Union keeps the
chronological order obvious (one array, scan in time order). Parallel
arrays avoid the `kind` tag and cell waste but require a separate
time-sorted index for consumers. Lean union unless a profiling
reason emerges to split.

## Scope of the refactor

- **In scope**: rewrite the data side (`cl_hub_demo_event.c`,
  `cl_hub_demo_event.h`, `cl_hub_mvd_event.c`, `cl_hub_dem_event.c`
  and the fragstats hook callers) from scratch. Disregard previous
  event-code design; new file.
- **Out of scope for this iteration**:
  - `engine/web/bindings.cpp` — leave the old surface in place; the
    JS consumer doesn't move until the engine data is clean.
  - Slipgate-side log.parse / demo analytics — same. Updated after
    the engine surface stabilizes, then synced per [[event-output-sync]].

## Existing context to preserve / port

These are previously-completed pieces of work; their semantics
survive even though the surrounding architecture changes:

- fragstats correctness fixes in `engine/client/fragstats.c`
  (spectator filter, 31-char name cap, gamedir filter, version
  handshake + arg-count validation + line-numbered warnings) —
  these belong to the upstream obit parser, not to the event layer.
  Untouched by this refactor.
- Match-time gate via `Hub_DemoEvent_InMatchTime()` and the
  countdown scan. Still gates which raw rows phase 1 accepts.
- KTX stats JSON capture (`hub_ktxstats_json`). Independent of
  the event kind redesign.
- Player roster building (`hub_demo_players[]`,
  `Hub_DemoEvent_RegisterPlayer`). The roster is built from any
  userid that appears in any raw buffer during phase 1, then
  finalized in phase 2 from `cl.players[]`.
- Item-hold span tracking (`hub_demo_spans[]`) — independent of
  event kind redesign; rebuild it in phase 2 from `tooks[]` and
  `deaths[]` (a span opens at a TOOK on a tracked bit, closes at
  the matching loss or at the holder's death).

Removed by this refactor (artifacts of the old emit-while-uncertain
design — no longer needed once phase 1 is observation-only):

- `inflight_origin_indices` + the `Hub_DemoEvent_OnPlayerinfo`
  deferred refresh.
- `fragstats_last_event_index` per-slot back-pointer.
- `pending_event_index` one-sided fragstats holder.
- The patch-in-place loop in `Hub_DemoEvent_OnFragStatsKill` with
  its index compaction and per-slot pointer fix-up.
- `killer_origin` deferred refresh (the killer side added in the
  prior session): in the new model, deaths[] captures victim_origin
  at end-of-frame, and the killer's origin is read at end-of-frame
  during phase 2 reconciliation from the death_message's frame
  via a phase-1 sidecar (`killer_origin_snapshots[]` keyed by
  death_message index) so it has the same "captured when known"
  guarantee.

## Honest gaps under "no guessing"

The redesign does not relax the existing principle that an event is
only emitted when its fields are derivable from observation, not
inferred from approximations:

- TOOK from STAT_ITEMS gain transitions: only emit for tracked bits
  where the gain edge is unambiguous. Existing logic in
  `update_item_spans` covers this.
- DEATH from STAT_HEALTH transition: emits with origin from
  playerstate (post-OnPlayerinfo refresh). `killer_origin` only
  populated when the killer slot is resolvable.
- MOD_EVENT(ctf_capture): emitted from the fragstats flag-capture
  obit match. Sure data: the pattern matched, the userid is from
  cl.players[].userid lookup.
- backpack_user_id on TOOK: only set when a corresponding DROPS
  internal row matched. Unmatched TOOKs get backpack_user_id = 0
  (not "guessed dropper").

## Verification plan

1. Build `gl-rel LINK_EZHUD=1 LINK_OPENSSL=1` (web target) clean.
2. Run `demo_events_scan` against a known MVD demo with mixed
   events (frags, pickups, runes, CTF). Compare event stream to the
   pre-refactor scan output to confirm no semantic loss.
3. Spot-check: every flag-touch event should be a TOOK with
   IT_KEY1 or IT_KEY2 set. Every capture should be a
   MOD_EVENT(ctf_capture). Every backpack pickup should be a TOOK
   with backpack_user_id != 0.
4. Confirm `bindings.cpp` still compiles against the old field
   names until it's explicitly migrated.

## File touchpoints

- `engine/client/cl_hub_demo_event.h` — new struct shape, kinds.
- `engine/client/cl_hub_demo_event.c` — rewrite from scratch:
  reset, emit, attribution-merge pass, scan dispatcher,
  match-time gate.
- `engine/client/cl_hub_demo_event_internal.h` — internal hooks.
- `engine/client/cl_hub_mvd_event.c` — MVD-specific hooks
  (mvdhidden_*, KTX took/drop/bp, stats JSON).
- `engine/client/cl_hub_dem_event.c` — NQ .dem-specific hooks
  (svc_updatefrags deltas).
- `engine/client/fragstats.c` — keep the existing
  `Hub_DemoEvent_OnFragStats*` call sites; only the function
  bodies behind them change.

## Open questions

- Do we want to keep `BACKPACK_PICKUP` as a *kind* hint on TOOK, or
  is "non-zero backpack_user_id" enough to derive it consumer-side?
  Latter is cleaner; the kind tag becomes redundant.
- Multi-bit backpack drops (RL + LG): emit one TOOK per bit (matches
  current behavior in `Hub_DemoEvent_OnKtxBackpackPickup`), or one
  TOOK with a multi-bit `items` mask? Per-bit is cleaner downstream
  for weapon spans; keep it.
- MOD_EVENT taxonomy: enum vs string? Enum is type-safe but couples
  every new mod event to a header bump. String is permissive but
  invites typos. Lean enum, add new values as needed.
