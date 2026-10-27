#include <emscripten/bind.h>
#include <emscripten/val.h>
#include <string>
#include <strings.h>
#include "quakedef.h"
#include "../client/cl_hub_cam.h"
#include "../client/cl_hub_participants.h"
#include "../client/cl_hub_demo.h"
#include "../client/cl_hub_ktxstats.h"
#include "../client/cl_hub_demo_event.h"

using namespace emscripten;

// Bindings exposing engine state to the embedding web app (hub.quakeworld.nu).
// Keep this to what the hub uses; static helpers are defined after EMSCRIPTEN_BINDINGS.

static std::string     hub_rgb_to_hex(const unsigned char rgb[3]);
static emscripten::val hub_bytes_copy(const char *bytes);
static void            hub_demo_jump_seconds(double seconds);

EMSCRIPTEN_BINDINGS(browser_api) {
	class_<player_info_t>("PlayerInfo")
		.property("userid", &player_info_t::userid)
		.function("getTeamPlain", +[](player_info_t& self) -> std::string {
			conchar_t buffer[MAX_INFO_KEY];
			char out[MAX_INFO_KEY];
			COM_ParseFunString(CON_WHITEMASK, self.team, buffer, sizeof(buffer), qfalse);
			COM_DeFunString(buffer, NULL, out, sizeof(out), qtrue, qfalse);
			return std::string(out);
		})
		.function("setUserInfo", +[](player_info_t& self, emscripten::val jskey, emscripten::val jsvalue) -> emscripten::val {
			const std::string key = jskey.as<std::string>();
			const std::string value = jsvalue.as<std::string>();
			bool result = InfoBuf_SetKey(&self.userinfo, key.c_str(), value.c_str());
			return emscripten::val(result);

		}, allow_raw_pointers());

	class_<client_state_t>("ClientState")
		.function("getMatchElapsed", +[](client_state_t& self) -> emscripten::val {
			int elapsed = Hub_GetMatchElapsedMs();
			if (elapsed < 0)
				return emscripten::val::null();
			return emscripten::val(elapsed);
		})
		.function("getDemoInfo", +[](client_state_t& self) -> emscripten::val {
			// File-walked scan snapshot captured at demo load time
			// (see cl_hub_demo_timeline.c). null when no scan has run
			// (QTV streams, unseekable sources, unsupported formats).
			if (!cls.lastdemoname[0])
				return emscripten::val::null();

			// HUB: elapsed 0 (start / just rewound) is a valid position, not "unknown".
			int elapsed_ms  = Hub_GetDemoElapsedMs();
			if (elapsed_ms < 0)
				return emscripten::val::null();

			extern int hub_demo_timelimit_ms;
			extern int hub_demo_countdown_ms;
			extern int hub_demo_total_ms;
			extern int hub_demo_match_end_ms;
			if (hub_demo_total_ms <= 0)
				return emscripten::val::null();
			// Split the post-match remainder into overtime + intermission.
			// NQ provides an observed match-end timestamp (sniffed from
			// the "The match is over" print) so the intermission tail is
			// known precisely; the leftover before it is overtime. QW/MVD
			// has no equivalent, so we fall back to the timelimit-based
			// math (overtimes are always multiples of 60s; intermission
			// is the sub-minute remainder).
			int overtime_ms;
			int intermission_ms;
			if (hub_demo_match_end_ms > 0)
			{
				int overtime_raw = hub_demo_match_end_ms - hub_demo_countdown_ms - hub_demo_timelimit_ms;
				if (overtime_raw < 0) overtime_raw = 0;
				overtime_ms     = overtime_raw;
				intermission_ms = hub_demo_total_ms - hub_demo_match_end_ms;
				if (intermission_ms < 0) intermission_ms = 0;
			}
			else
			{
				int post_match_ms = hub_demo_total_ms - hub_demo_countdown_ms - hub_demo_timelimit_ms;
				if (post_match_ms < 0) post_match_ms = 0;
				overtime_ms     = (post_match_ms / 60000) * 60000;
				intermission_ms = post_match_ms - overtime_ms;
			}
			// Format tag for the web side. Mirrors cls.demoplayback
			// (DPB_*) so consumers can adapt the UI per-format. A
			// QWD->MVD wrap still reports "mvd" here; check is_single_pov
			// to tell it apart from a real multi-POV MVD.
			const char *format = "?";
			switch (cls.demoplayback)
			{
			case client_static_t::DPB_QUAKEWORLD: format = "qwd"; break;
			case client_static_t::DPB_MVD:        format = "mvd"; break;
			case client_static_t::DPB_NETQUAKE:   format = "nq";  break;
			default: break;
			}

			// POV user id: -1 when the userid isn't resolvable yet
			// (early prespawn) OR the demo is genuinely multi-POV.
			// is_single_pov is the canonical "is this a single-POV
			// demo?" signal - independent of userid resolution timing
			// so it stays stable from the moment the timeline scan
			// completes. Both resolved in cl_hub_demo.c so engine /
			// CSQC / web all see the same answer.
			int pov_user_id   = Hub_GetDemoPovUserId();
			bool is_single_pov = Hub_IsSinglePovDemo() != 0;

			emscripten::val result = emscripten::val::object();
			result.set("format",          std::string(format));
			result.set("elapsed_ms",      elapsed_ms);
			result.set("total_ms",        hub_demo_total_ms);
			result.set("timelimit_ms",    hub_demo_timelimit_ms);
			result.set("countdown_ms",    hub_demo_countdown_ms);
			result.set("overtime_ms",     overtime_ms);
			result.set("intermission_ms", intermission_ms);
			result.set("pov_user_id",     pov_user_id);
			result.set("is_single_pov",   is_single_pov);
			return result;
		})
		.function("getPlayers", +[](client_state_t& self) -> emscripten::val {
			emscripten::val result = emscripten::val::array();

			char *demoplayback = Cmd_GetMacroValue("demoplayback");
			bool is_dem_playback = demoplayback && strcmp(demoplayback, "demplayback") == 0;

			int n_player = 0;
			for (int i = 0; i < cl.allocated_client_slots; i++) {
			    player_info_t *player = &(cl.players[i]);

			    if (!player->name[0] || player->spectator) {
			        continue;
			    }

			    if (is_dem_playback && player->frags < 1 && player->rbottomcolor == 0 && player->rtopcolor == 0) {
			        continue;
			    }

			    result.set(n_player++, player);
			}
			return result;
		}, allow_raw_pointers());

	function("getClientState", +[]() -> client_state_t* {
		return &cl;
	}, allow_raw_pointers());

	function("getCvar", +[](std::string name) -> std::string {
		return std::string(Cvar_VariableString(name.c_str()));
	});

	// True while the console has key focus (keys go to the console, not binds).
	function("isConsoleOpen", +[]() -> bool {
		return Key_Dest_Has(kdm_console) != 0;
	});

	// Active autotrack mode: "user", "high", "killer", "mod" or "stats".
	// Explicit picks (track_userid, player clicks) switch it to "user" without touching cl_autotrack.
	function("getAutotrackMode", +[]() -> std::string {
		return std::string(Cam_AutoTrackModeName());
	});

	// Userid of the player the main view is tracking, -1 when free-flying or not connected.
	function("getTrackedUserid", +[]() -> int {
		int slot = Cam_TrackNum(&cl.playerview[0]);
		if (slot < 0 || slot >= MAX_CLIENTS)
			return -1;
		return cl.players[slot].userid;
	});

	// Writes fte.cfg synchronously (cfg_save), so it also works from pagehide where no frame runs.
	function("saveConfig", +[]() {
		Cmd_ExecuteString("cfg_save", RESTRICT_LOCAL);
	});

	function("setWebLogEnabled", +[](bool enabled) {
		extern qboolean web_log_enabled;
		web_log_enabled = enabled ? (qboolean)true : (qboolean)false;
	});

	// Web app's hover-on-canvas signal. The embedding page already tracks
	// this for hiding the demo time slider when the cursor leaves the
	// canvas; routing it through here lets CSQC overlays follow the same
	// rule (currently consumed by hub_addon/src/mouselock.qc to hide the
	// AIM button). Stored as a float cvar so CSQC reads it via
	// autocvar_canvas_hover. The cvar is created on first call (Cvar_Get
	// returns a registered cvar_t even if no QC declared it yet).
	function("setCanvasHover", +[](bool hovered) {
		Cvar_Set(Cvar_Get("canvas_hover", "1", 0, "Hub state"),
		         hovered ? "1" : "0");
	});

	// Web app's focus-on-canvas signal. Parallels setCanvasHover; the page
	// should wire its canvas focus/blur listeners (or whatever owns the
	// "is the user typing into FTE vs. into some external input" call)
	// through here. CSQC consults autocvar_canvas_focus to decide whether
	// keys it would otherwise swallow (Tab, Space) should reach the
	// engine. Defaults to "1" so the QC gate is permissive until the web
	// app explicitly downgrades it.
	function("setCanvasFocus", +[](bool focused) {
		Cvar_Set(Cvar_Get("canvas_focus", "1", 0, "Hub state"),
		         focused ? "1" : "0");
	});

	// Fast-parse the current demo to extract per-player events
	// (currently STAT_HEALTH-based deaths during MATCH_INPROGRESS).
	// Idempotent: the underlying scan caches per demo path and returns
	// the prior result on repeat calls. First call blocks the JS event
	// loop for up to ~1s while the demo is replayed without rendering.
	// Returns an array of { time_ms, kind, victim_slot } objects sorted
	// by time_ms. Empty array if the demo can't be scanned (no demo
	// loaded, qtv stream, unseekable, or non-MVD).
	//
	// To show a loading UI, yield to the browser before invoking so the
	// DOM repaints before the freeze:
	//
	//   async function loadEvents() {
	//     setLoadingVisible(true);
	//     await new Promise(r =>
	//       requestAnimationFrame(() => requestAnimationFrame(r)));
	//     const events = Module.getDemoEvents();
	//     setLoadingVisible(false);
	//     return events;
	//   }
	//
	// Two nested rAF calls: the first commits the DOM state, the second
	// guarantees the browser has painted before the blocking call.
	function("getDemoEvents", +[]() -> emscripten::val {
		Hub_DemoEvent_Scan();

		// TP_LocationName early-returns "someplace" unless cls.state
		// is ca_active. The scan's CL_PlayDemoStream restart leaves
		// cls.state at ca_demostart; force the flag locally for the
		// duration so origins resolve to .loc zones.
		cactive_t saved_state = cls.state;
		cls.state = ca_active;
		TP_ReloadCurrentLocs();

		auto resolve_loc = [](const float *o) -> std::string {
			bool has_origin = (o[0] != 0 || o[1] != 0 || o[2] != 0);
			if (!has_origin) return std::string();
			const char *l = TP_LocationName(const_cast<float *>(o));
			return (l && strcmp(l, "someplace")) ? std::string(l)
			                                    : std::string();
		};

		auto vec3_to_val = [](const float *v) -> emscripten::val {
			emscripten::val o = emscripten::val::object();
			o.set("x", v[0]);
			o.set("y", v[1]);
			o.set("z", v[2]);
			return o;
		};

		emscripten::val events = emscripten::val::array();
		for (int i = 0; i < hub_demo_event_count; i++) {
			hub_demo_event_t *source = &hub_demo_events[i];
			emscripten::val ev = emscripten::val::object();
			ev.set("kind", (int)source->kind);
			switch (source->kind) {
			case HDE_KIND_TOOK:
				ev.set("time_ms",          source->u.took.time_ms);
				ev.set("user_id",          source->u.took.user_id);
				ev.set("items",            (double)source->u.took.items);
				ev.set("backpack_user_id", source->u.took.backpack_user_id);
				ev.set("origin",           vec3_to_val(source->u.took.origin));
				ev.set("location",         resolve_loc(source->u.took.origin));
				break;
			case HDE_KIND_DEATH: {
				auto death_user_to_val = [&](const hub_demo_death_user_t &u) {
					emscripten::val o = emscripten::val::object();
					o.set("user_id",   u.user_id);
					o.set("weapon_id", (double)u.weapon_id);
					o.set("items",     (double)u.items);
					o.set("origin",    vec3_to_val(u.origin));
					return o;
				};
				ev.set("time_ms",       source->u.death.time_ms);
				ev.set("death_type_id", (double)source->u.death.death_type_id);
				ev.set("message",       std::string(source->u.death.message));
				ev.set("victim",  death_user_to_val(source->u.death.victim));
				ev.set("killer",  death_user_to_val(source->u.death.killer));
				ev.set("location", resolve_loc(source->u.death.victim.origin));
				break;
			}
			case HDE_KIND_MOD_EVENT:
				ev.set("time_ms",  source->u.mod.time_ms);
				ev.set("user_id",  source->u.mod.user_id);
				ev.set("mod_kind", (int)source->u.mod.mod_kind);
				ev.set("origin",   vec3_to_val(source->u.mod.origin));
				ev.set("location", resolve_loc(source->u.mod.origin));
				break;
			default:
				break;
			}
			events.set(i, ev);
		}

		emscripten::val players = emscripten::val::array();
		for (int i = 0; i < hub_demo_player_count; i++) {
			emscripten::val p = emscripten::val::object();
			p.set("user_id",   hub_demo_players[i].user_id);
			p.set("name",      std::string(hub_demo_players[i].name));
			p.set("team",      std::string(hub_demo_players[i].team));
			p.set("is_active", (bool)hub_demo_players[i].is_active);
			players.set(i, p);
		}

		emscripten::val spans = emscripten::val::array();
		for (int i = 0; i < hub_demo_span_count; i++) {
			emscripten::val sp = emscripten::val::object();
			sp.set("start_ms",    hub_demo_spans[i].start_ms);
			sp.set("end_ms",      hub_demo_spans[i].end_ms);
			sp.set("user_id",     hub_demo_spans[i].user_id);
			sp.set("items",       (double)hub_demo_spans[i].items);
			sp.set("was_dropped", (bool)hub_demo_spans[i].was_dropped);
			sp.set("frag_count",  hub_demo_spans[i].frag_count);
			spans.set(i, sp);
		}

		emscripten::val result = emscripten::val::object();
		result.set("events",  events);
		result.set("players", players);
		result.set("spans",   spans);

		cls.state = saved_state;
		return result;
	});

	// Returns the embedded ktxstats JSON string, or null if the demo
	// carries no mvdhidden_demoinfo payload (most non-KTX MVDs and
	// live games). Hub_KtxStats_Scan walks the demo file directly and
	// only parses hidden-message frame bodies (seeking past everything
	// else). Cheap enough to run synchronously - tens of ms instead of
	// the ~1s a full event scan would cost.
	function("getKtxStats", +[]() -> emscripten::val {
		Hub_KtxStats_Scan();
		if (!hub_ktxstats_json) return emscripten::val::null();
		return emscripten::val(std::string(hub_ktxstats_json));
	});

	// Single entry point for console commands the web app pushes into
	// the engine. Replaces the JS-side `command(name, value)` wrapper
	// that built "name [value]\n" and called FTEC.cbufadd directly.
	//
	// `value` may be undefined, a string, or a number. Undefined sends
	// just the command name; otherwise the value is appended after a
	// space. Numbers stringify with %g.
	//
	// "demo_jump" is special-cased: the engine's built-in demo_jump
	// expects absolute level-time seconds, but the web app thinks in
	// demo-relative seconds. hub_demo_jump_seconds applies the NQ
	// start_offset shift and the clamp/no-op logic that JS used to
	// route through Module.demoJump.
	function("command", +[](std::string name, emscripten::val value) {
		if (name == "demo_jump") {
			double seconds = value.isUndefined() || value.isNull()
				? 0.0
				: value.as<double>();
			hub_demo_jump_seconds(seconds);
			return;
		}
		char buf[1024];
		if (value.isUndefined() || value.isNull()) {
			Q_snprintfz(buf, sizeof(buf), "%s\n", name.c_str());
		} else if (value.isString()) {
			Q_snprintfz(buf, sizeof(buf), "%s %s\n",
			            name.c_str(), value.as<std::string>().c_str());
		} else if (value.isNumber()) {
			Q_snprintfz(buf, sizeof(buf), "%s %g\n",
			            name.c_str(), value.as<double>());
		} else {
			Q_snprintfz(buf, sizeof(buf), "%s\n", name.c_str());
		}
		Cbuf_AddText(buf, RESTRICT_LOCAL);
	});

	// Players and teams from the engine participant model (cl_hub_participants.c, shared with
	// ezhud). Players: non-spectators sorted by name. Teams: only with >2 players and exactly 2 teams.
	function("getParticipants", +[]() -> emscripten::val {
		hub_participants_t parts;
		Hub_BuildParticipants(&parts);

		int tracked_slot   = Cam_TrackNum(&cl.playerview[0]);
		int tracked_userid = (tracked_slot >= 0 && tracked_slot < MAX_CLIENTS) ? cl.players[tracked_slot].userid : -1;

		emscripten::val players = emscripten::val::array();
		for (int i = 0; i < parts.player_count; i++) {
			const hub_participant_player_t &source = parts.players[i];
			char team_unicode[HUB_PARTICIPANT_NAME_BYTES];
			char team_ascii[HUB_PARTICIPANT_ASCII_BYTES];
			Hub_QuakeStringToUnicode(source.team_bytestr, team_unicode, sizeof(team_unicode));
			Hub_QuakeStringToAscii(source.team_bytestr, team_ascii, sizeof(team_ascii));

			emscripten::val player = emscripten::val::object();
			player.set("userid",       source.userid);
			player.set("frags",        source.frags);
			player.set("name",         std::string(source.name_unicode));
			player.set("name_bytes",   hub_bytes_copy(source.name_bytestr));
			player.set("name_ascii",   std::string(source.name_ascii));
			player.set("team",         std::string(team_unicode));
			player.set("team_bytes",   hub_bytes_copy(source.team_bytestr));
			player.set("team_ascii",   std::string(team_ascii));
			player.set("top_color",    source.top_color);
			player.set("bottom_color", source.bottom_color);
			player.set("top_rgb",      hub_rgb_to_hex(source.top_rgb));
			player.set("bottom_rgb",   hub_rgb_to_hex(source.bottom_rgb));
			player.set("is_bot",       source.is_bot != 0);
			player.set("is_tracked",   source.userid == tracked_userid);
			players.set(i, player);
		}

		emscripten::val teams = emscripten::val::array();
		for (int i = 0; i < parts.team_count; i++) {
			const hub_participant_team_t &source = parts.teams[i];
			int player_count = 0;
			for (int j = 0; j < parts.player_count; j++) {
				if (!strcmp(parts.players[j].team_bytestr, source.team_bytestr))
					player_count++;
			}

			emscripten::val team = emscripten::val::object();
			team.set("name",         std::string(source.team_unicode));
			team.set("name_bytes",   hub_bytes_copy(source.team_bytestr));
			team.set("name_ascii",   std::string(source.team_ascii));
			team.set("frags",        source.frag_sum);
			team.set("top_color",    source.top_color);
			team.set("bottom_color", source.bottom_color);
			team.set("top_rgb",      hub_rgb_to_hex(source.top_rgb));
			team.set("bottom_rgb",   hub_rgb_to_hex(source.bottom_rgb));
			team.set("player_count", player_count);
			teams.set(i, team);
		}

		emscripten::val result = emscripten::val::object();
		result.set("players", players);
		result.set("teams",   teams);
		return result;
	});
}

// ---- Static helpers ------------------------------------------------------

// "#rrggbb" for a palette RGB triplet.
static std::string hub_rgb_to_hex(const unsigned char rgb[3]) {
	char hex[8];
	snprintf(hex, sizeof(hex), "#%02x%02x%02x", rgb[0], rgb[1], rgb[2]);
	return std::string(hex);
}

// Uint8Array copy of a quake byte string (^X markup and high-bit chars kept), safe after return.
static emscripten::val hub_bytes_copy(const char *bytes) {
	return emscripten::val::global("Uint8Array").new_(
		typed_memory_view(strlen(bytes), (const unsigned char *) bytes));
}

// Seek the active demo to `seconds` from the start. Called from the
// command("demo_jump", ...) dispatch. Floors and clamps to >= 0;
// no-ops when no demo is loaded,
// or when the requested second is within 1s of current. Clamps to
// one second before the end so seeks can't land past the last packet
// and trigger the EOF/disconnect path. Hub_GetDemoElapsedMs reports
// demo-relative ms; the engine's `demo_jump` command takes the same
// unit as demtime (absolute level time for NQ). Shift the
// demo-relative request back into that frame so NQ seeks land in the
// right place. QW/MVD have start_offset = 0, so this is a no-op there.
static void hub_demo_jump_seconds(double seconds) {
	if (!cls.lastdemoname[0]) return;
	int elapsed_ms = Hub_GetDemoElapsedMs();
	if (elapsed_ms < 0) return;
	int new_secs = (int) floor(seconds);
	if (new_secs < 0) new_secs = 0;
	extern int hub_demo_total_ms;
	if (hub_demo_total_ms > 1000)
	{
		int max_secs = (hub_demo_total_ms - 1000) / 1000;
		if (new_secs > max_secs) new_secs = max_secs;
	}
	float current_secs = elapsed_ms / 1000.0f;
	if (fabsf((float) new_secs - current_secs) < 1.0f) return;
	extern int hub_demo_start_offset_ms;
	int abs_secs = new_secs + (hub_demo_start_offset_ms + 500) / 1000;
	char cmd[64];
	snprintf(cmd, sizeof(cmd), "demo_jump %d\n", abs_secs);
	Cbuf_AddText(cmd, RESTRICT_LOCAL);
}
