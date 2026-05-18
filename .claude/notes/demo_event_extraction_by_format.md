---
name: demo-event-extraction-by-format
description: "What kinds of game events are extractable from each demo format (NQ .dem, QWD, MVD) in this FTEQW fork, and what the hard limits are."
metadata: 
  node_type: memory
  type: project
  originSessionId: a58ca070-1083-44a4-8a3d-84dac4d83a59
---

The Hub demo event scanner (`engine/client/cl_hub_demo_events.c`) is currently
**MVD-only** — gated at `cl_hub_demo_events.c:695`
(`if (cls.demoplayback != DPB_MVD) return -1;`). Other formats produce zero
events today.

**Why:** the existing scanner depends on three MVD-exclusive sources:

1. `dem_stats` per-player stat broadcasts (lets it see every client's
   STAT_HEALTH / STAT_ITEMS — used for deaths and pickups)
2. MVD hidden messages: `//ktx took`, `//ktx drop`, `//ktx bp`,
   `mvdhidden_dmgdone`, `mvdhidden_demoinfo` (damage attribution, backpack
   tracking, KTX stats JSON)
3. Per-player viewangles/origin in MVD frames (positions for non-POV players)

**Per-format coverage:**

- **MVD** — full coverage: deaths, pickups, weapon drops, backpack pickups,
  damage attribution (killer/victim/weapon), weapon-hold spans, KTX stats
  JSON. ~100% of designed feature surface.

- **NQ (.dem)** — see [[nq-demo-event-extraction-tiers]] for details. Roughly
  70% POV-only / 30% other-player coverage. Tier 1 (clean wire events): roster,
  frag deltas, intermission, POV stats/death/pickup/weapon-spans. Tier 2 (text-
  parsed): kill attribution via id1 obituary strings in svc_print (mod-
  dependent). Tier 3 (effects only): TE_ entities without attribution.

- **QWD (single-POV QW)** — see [[qwd-demo-event-extraction-tiers]]. ~85-95%
  of MVD coverage. **Key insight:** `//ktx took/drop/bp` events ride on
  `svc_stufftext` (`cl_parse.c:7476-7491`), which is standard QW protocol —
  so they fire in QWD too. The existing `Hub_DemoEvents_OnKtxTook/Drop/
  BackpackPickup` hooks already work; only the scanner gate
  (`cl_hub_demo_events.c:695`) blocks them. Missing vs MVD: no per-player
  `dem_stats` broadcasts (POV-only stats), no binary `mvdhidden_*` (so no
  damage attribution and no KTX JSON dump).

**Hard limits common to non-MVD formats:** no damage attribution across
players, no per-non-POV stat broadcasts (so other players' deaths/pickups
invisible), no weapon-drop/backpack wire messages, no KTX JSON dump.

**Reusable building blocks (protocol-agnostic):**

- `update_item_spans` (`cl_hub_demo_events.c:217-272`) — weapon-hold spans
  from STAT_ITEMS bit changes. Reusable for POV-only span tracking in any
  format.
- `Hub_DemoEvents_OnStatUpdate` (`cl_hub_demo_events.c:473-512`) — death/
  pickup detector. Already protocol-agnostic in shape; only the dispatcher in
  `CL_SetStatNumeric` (`cl_parse.c:6138`) is MVD-gated.
- `CLNQ_ParseNQPrints` (`cl_parse.c:9264`) — natural place for an NQ kill-
  message parser hooked off svc_print obituary text.
