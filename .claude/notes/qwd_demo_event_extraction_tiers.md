---
name: qwd-demo-event-extraction-tiers
description: "Tiered breakdown of which game events are extractable from QWD (single-POV QuakeWorld) demo files, with svc_/stufftext sources and parse-site refs."
metadata: 
  node_type: memory
  type: project
  originSessionId: a58ca070-1083-44a4-8a3d-84dac4d83a59
---

QWD demo event extraction feasibility. Companion to
[[demo-event-extraction-by-format]] and [[nq-demo-event-extraction-tiers]].

**Key insight:** QWD shares the QuakeWorld wire protocol with MVD. The KTX
`//ktx took / drop / bp` events arrive via `svc_stufftext`
(`cl_parse.c:7476-7491`) — **present in QWD too**. Existing hooks
`Hub_DemoEvents_OnKtxTook/Drop/BackpackPickup` already fire during QWD
playback; they're only discarded because the scanner gate
(`cl_hub_demo_events.c:695`) rejects non-MVD.

**What MVD has that QWD does not:**

1. `dem_stats` per-player stat broadcasts — QWD only carries POV's stats
2. Binary `mvdhidden_*` messages — no `mvdhidden_dmgdone` (damage attribution),
   no `mvdhidden_demoinfo` (KTX JSON stats)

**Frame format:** QWD per-frame `[float time (abs, 4B)][byte cmd][body]`;
MVD `[byte msec (delta, 1B)][byte cmd][body]`. Same `dem_*` cmd-byte semantics.
`Hub_DemoTimeline_ScanQw(file, is_mvd)` already handles both.

**Tier 1 — already wired, will fire once gate is opened:**

| Event | Source | Site |
|-------|--------|------|
| Item pickup (all players) | `//ktx took` stufftext | `cl_parse.c:7190` → `Hub_DemoEvents_OnKtxTook` |
| Weapon drop (all players) | `//ktx drop` stufftext | `cl_parse.c:7060` → `Hub_DemoEvents_OnKtxDrop` |
| Backpack pickup (all players) | `//ktx bp` stufftext | `cl_parse.c:6982` → `Hub_DemoEvents_OnKtxBackpackPickup` |
| Player roster (name/team/colors/spec/VIP) | `svc_updateuserinfo` blob | `cl_parse.c:5860` |
| Frag deltas (all players) | `svc_updatefrags` | cl_parse.c |
| Ping | `svc_updateping` | cl_parse.c |
| Match end | `svc_intermission` | cl_parse.c |
| Pause | `svc_setpause` | cl_parse.c |
| Demo clock | per-frame float time | `cl_demo.c:752` |

**Frag event emission rule:** `svc_updatefrags` gives the scorer but not the
victim. Emit the frag event with the known side filled in and the unknown
side as `-1` (either `killer_user_id` or `victim_user_id` may be `-1`). Do
NOT guess attribution from timing or positional heuristics. The Tier 3
obituary parser may later upgrade an event with the missing side; absent
that, `-1` stands. Consumers must accept `-1` as "unknown".

**Tier 2 — POV-only (single-client stats):**

POV death (STAT_HEALTH 0), POV stat-derived weapon-hold spans (reuse
`update_item_spans` `cl_hub_demo_events.c:217-272`). Other-player weapon-holds
inferable from `//ktx took`+`//ktx drop` events alone. Gate:
`CL_SetStatNumeric` at `cl_parse.c:6132-6151` only fires the event hook for
DPB_MVD; would need to extend to DPB_QUAKEWORLD.

**Tier 3 — text-parsed (mod-dependent):**

QW kill obituaries in `svc_print`. KTX has fairly standardised set distinct
from id1 NQ. `//wps` weapon stats stufftext (`cl_parse.c:7459`) already parsed
for ezhud. Chat = svc_print ID=1.

**Tier 4 — effects only (TEQW_*, `cl_tent.c:1137-1670`):**

Richer than NQ: TEQW_QWGUNSHOT (with count byte), TEQW_RAILTRAIL,
TEQW_LIGHTNINGBLOOD, TEQW_BEAM (origin+dest), etc. No attacker entity link.

**Tier 5 — unrecoverable:**

Damage attribution across players, per-non-POV stat broadcasts, KTX JSON
stats dump, non-POV per-frame origins.

**Coverage estimate vs MVD:** ~95% of pickup/drop/bp surface, ~100% of
roster/frag/intermission surface, ~90% of POV death/span surface, 0% damage
attribution, 0% KTX JSON. Substantially better than NQ — most KTX hooks Just
Work once the gate accepts DPB_QUAKEWORLD.

**Implementation gates to remove for QWD:**

- `cl_hub_demo_events.c:695` — `Hub_DemoEvents_Scan` MVD-only gate (extend to
  DPB_QUAKEWORLD; keep `Hub_DemoStats_Scan` MVD-only since it needs
  `mvdhidden_demoinfo`)
- `cl_parse.c:6138` — `CL_SetStatNumeric` MVD-only event-hook gate (extend
  for POV stats in QWD)
