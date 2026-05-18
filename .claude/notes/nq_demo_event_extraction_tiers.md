---
name: nq-demo-event-extraction-tiers
description: "Tiered breakdown of which game events are extractable from NetQuake .dem demo files, with svc_ message sources and parse-site file refs."
metadata: 
  node_type: memory
  type: project
  originSessionId: a58ca070-1083-44a4-8a3d-84dac4d83a59
---

NQ demo event extraction feasibility, organised by reliability tier. Companion
to [[demo-event-extraction-by-format]].

**Tier 1 — clean wire events (reliable, protocol-grounded):**

| Event | NQ message | Parse site |
|-------|-----------|-----------|
| Player joins / renames | `svc_updatename` | `cl_parse.c:9975` |
| Team/color change | `svc_updatecolors` | `cl_parse.c:10004` |
| Frag delta (all players, no attacker) | `svc_updatefrags` | `cl_parse.c:9993` |
| Spectator in/out | frags == -99 / -999 | `CLNQ_CheckPlayerIsSpectator` at `cl_parse.c:9366` |
| Match end | `svc_intermission` | cl_parse.c |
| End-of-level text | `svc_finale` | cl_parse.c |
| Demo clock | `svc_time` (already used) | `cl_hub_demo_timeline_nq.c:15` |
| POV damage taken | `svc_damage` (armor/blood/from-vec) | `cl_parse.c:10211` |
| POV stats (HP/items/weapons/ammo) | `svc_updatestat` / `svc_updatestatlong` | `cl_parse.c:10044+` |

Derived: POV-only death (STAT_HEALTH >0 → ≤0), POV-only pickup (STAT_ITEMS bit
gain), POV-only weapon-hold spans (RL/LG/quad/pent/ring bits — same logic as
MVD `update_item_spans`).

**Frag event emission rule:** `svc_updatefrags` gives us the scorer but not
the victim. Emit the frag event with the known side filled in and the
unknown side as `-1` (either `killer_user_id` or `victim_user_id` may be
`-1`). Do NOT guess attribution from timing or positional heuristics. A
Tier 3 obituary parser may later upgrade the event with the missing side;
absent that, `-1` stands. Consumers must accept `-1` as "unknown".

**Tier 2 — text-parsed (mod-dependent):**

NQ kill announcements come as plain text in `svc_print`
(handler `cl_parse.c:9748`, dispatcher `CLNQ_ParseNQPrints` at
`cl_parse.c:9264`). id1 has ~60-80 hardcoded obituary strings per weapon×cause.
Mod variants (1.5, AD, CRMod) override. Extractable with a regex parser:
kill (killer/victim/weapon), suicide, match start/end via `svc_centerprint`
(`cl_parse.c:9768`), chat lines ("name: ..." prefix).

**Tier 3 — effects only (no attribution):**

`svc_temp_entity` (`cl_tent.c:1108`, `CL_ParseTEnt`): TE_GUNSHOT, TE_SPIKE,
TE_SUPERSPIKE, TE_EXPLOSION, TE_TAREXPLOSION, TENQ_EXPLOSION2,
TE_LIGHTNING1/2/3, TE_TELEPORT, TE_LAVASPLASH. Origin only, no source player.
Useful for heatmaps / fire-density overlays.

**Tier 4 — fundamentally absent in .dem:**

Damage attribution across players, weapon drops, backpack pickups, non-POV
stat broadcasts (so other players' deaths/pickups invisible), KTX stats JSON,
per-frame origins for non-POV players.

**NQ frame format** (for any custom scanner that doesn't go through full
playback): `int msglength + 12 bytes viewangles (3 floats) + msglength bytes
body`. See `Hub_DemoTimeline_ScanNq` at `cl_hub_demo_timeline_nq.c:15` for
reference iteration.
