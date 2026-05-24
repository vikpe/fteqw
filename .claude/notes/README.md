# Project notes

Long-form analysis and reference notes for this repo. Committed to git so
they travel between machines and sessions.

## Index

- [Workflow rules](workflow.md) — always-run scripts, build/sync conventions
- [Build configurability inventory](build_configurability.md) — what FTE currently exposes (targets, flags, configs, games, formats, renderers, plugins, features); source of truth for what each macro does
- [Slim FTE plan (Phase 1)](slim_plan.md) — per-category keep/drop decisions for a quake.world-only wasm; open questions blocking config_qwslim.h authoring
- [Rust port plan (Phase 2)](rust_port_plan.md) — from-scratch Rust client (wgpu) for web + CLI + streambot; spec depends on slim plan
- [Demo event extraction by format](demo_event_extraction_by_format.md) — what events each demo format (NQ/QWD/MVD) yields and why MVD has the richest set
- [NQ demo event extraction tiers](nq_demo_event_extraction_tiers.md) — tiered breakdown of NetQuake .dem event recoverability with svc_ refs
- [QWD demo event extraction tiers](qwd_demo_event_extraction_tiers.md) — tiered breakdown of QWD event recoverability; key insight that //ktx events work in QWD too
