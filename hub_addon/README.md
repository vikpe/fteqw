QuakeWorld Demo Analysis CSQC Addon
===================================

This CSQC addon bundles several spectator and demo-analysis features for
QuakeWorld matches:

* **Powerup cameras** - picture-in-picture view of upcoming quad/pent
  pickups, driven by KTX item timers. If both spawn close together, pent
  wins.
* **Minimap** - top-down orthographic view of the map with cull volumes
  to peel away roofs, player markers (rings + arrowhead), health/armor
  bars, weapon labels, and through-wall doppelgangers for occluded
  players. Modes: off, picture-in-picture, split-screen, full-screen.
* **Score overlay** - centered top-of-screen 1v1 / 2-team score header
  with team-colored boxes and a match clock.
* **X-ray** - colored player silhouettes drawn through walls so the
  spectator can track action around corners.

Source layout
-------------

```
src/
  csplat.qc             - engine API dump (do not edit by hand)
  easing.qc             - EaseInExpo
  item_type.qc          - itemtype_t + lookups
  item_timer.qc         - powerup pickup/respawn timers
  powcam.qc             - powcam scheduler
  powcam_config.qc      - per-map powerup/camera database
  powcam_render.qc      - powcam overlay rendering
  powcam_commands.qc    - powcam console handlers
  xray.qc               - through-wall silhouettes
  score_overlay.qc      - 1v1 / 2-team header
  minimap.qc            - minimap render pass
  minimap_data.qc       - minimap shared state, primitives, color tables
  minimap_load.qc       - BSP auto-bounds + traceline narrowing + cull-file loading
  minimap_editor.qc     - interactive cull-volume editor (add/remove/export)
  minimap_players.qc    - player markers, labels, doppelgangers
  minimap_commands.qc   - minimap console handlers
  commands.qc           - top-level console dispatcher
  main.qc               - CSQC lifecycle hooks
  progs.src             - build manifest
```

Build
-----

```
make                       # uses `fteqcc` from PATH
FTEQCC=fteqcc64 make       # uses fteqcc64
```

Produces `csaddon.dat` (the engine looks for this filename; do not rename).

Contributing cameras
--------------------

The cameras are declared in `src/powcam_config.qc` via an embedded DSL to
make it a bit more accessible for non-programmers:

```c
map("e2m5",
    quad('8 -416 -16', camera(origin('169 -210 100'), angles('27 227 0'))),
    quad('-32 2432 88', camera(origin('54 2432 191'), angles('22 180 0'))),
    pent('-320 1088 -423', camera(origin('-154 1005 -306'), angles('41 135 0')))
),
```

To contribute a new camera, the easiest way right now is to use a client
that supports `/viewpos`, for example [QSS-M](https://qssm.quakeone.com/).

Launch QSS-M, load the map, type `/noclip` and set `fov 110` as that's
what the camera uses. Then fly to the desired location and type
`/viewpos copy` to copy the position and angles into the clipboard which
will look something like this:

```
(610 -772 716) 90 1 0
```

The first triplet is camera position (origin), and the latter is camera
angle.

To find the position of the powerup, open the .bsp in some editor and
search for `item_artifact_super_damage` (quad) and
`item_artifact_invulnerability` (pent). Alternatively:

```
strings foo.bsp | grep -A 5 -B 5 item_artifact
```

If the powerup does not show up, this is likely due to it being dropped
on the map. Try lowering the last value (Z) of the origin a bit.

Cvars
-----

Powcam:

* `powcam_enabled` - `0` or `1`.
* `powcam_intro` - seconds of lead-in before spawn.
* `powcam_outro` - seconds to keep camera up after pickup.
* `powcam_transition` - slide in/out duration (seconds).
* `powcam_bg_quad_color` - frame color for quad cameras.
* `powcam_bg_pent_color` - frame color for pent cameras.

X-ray:

* `xray` - `0` or `1`.
* `xray_alpha` - silhouette alpha at zero distance.
* `xray_distance` - how far through walls to see until faded out.
* `xray_color_team` - `r g b` team color.
* `xray_color_enemy` - `r g b` enemy color.

Minimap (see `minimap help` for in-game descriptions):

* `minimap_mode` - 0=off, 1=pip, 2=split, 3=full.
* `minimap_player_radius`, `_alpha`,
  `_teamcolor`/`_enemycolor`/`_selfcolor`,
  `_name_length`, `_name_size`.
* `minimap_editor` - 0/1; toggles the cull-volume editor (wireframes,
  highlight, bounding-box outline, add/remove/undo/export commands).
* `minimap_editor_show_all` - 0/1; when the editor is on, draw every
  volume regardless of distance from the player.

Score overlay: no cvars. Visibility is rule-based (hidden in coop; clock
hidden during pre-match standby; participant scores require exactly two
players or two teams).

Debug:

* `debug` - `0` or `1`; toggles diagnostic logging.

Commands
--------

Both commands print full descriptions when invoked with `help`.

* `powcam <subcmd>` - `active` (current schedule), `timers` (all tracked
  pickup timers), `recheck` (force-reschedule), `help`.
* `minimap <subcmd>` - `reload` (reparse cull file and re-derive
  bounds), `status` (current mode, map, volume count, view params,
  bbox), `probe` (top-down ASCII traceline coverage map of the BSP),
  `help`.
* `minimap_editor_add` - first call records the player's origin as
  one AABB corner; second call closes the volume at the current origin.
* `minimap_editor_remove` - delete the currently highlighted volume.
* `minimap_editor_undo` - reverse the most recent add or remove.
* `minimap_editor_export` - write current volumes to
  `maps/<mapname>.cull` and copy to the system clipboard.

Compatibility
-------------

For the time being this addon only works with the
[hub.quakeworld.nu](https://hub.quakeworld.nu) fork of
[FTE](https://www.fteqw.org).

The addon somewhat works when loaded in an official release of FTE, but
due to some bugs and limitations found during development there are
currently some issues with timers when seeking. Will work anywhere FTE
runs later on.
