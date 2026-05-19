#include <emscripten/bind.h>
#include <emscripten/val.h>
#include <string>
#include <strings.h>
#include "quakedef.h"
#include "fragstats.h"
#include "../client/cl_hub_cam.h"
#include "../client/cl_hub_participants.h"
#include "../client/cl_hub_demo.h"
#include "../client/cl_hub_ktxstats.h"
#include "../client/cl_hub_demo_event.h"

using namespace emscripten;

/**
 * // Sample use of the browser API.
 * //
 * // All functions not returning plain strings and numbers return live
 * // references to the WASM heap and thus references values that update
 * // as the engine runs. This allows the frontend to fetch references
 * // at start, and continue pull data from these throughout the session.
 * //
 * // Some functions return Quake charset strings. These are exposed
 * // as Uint8Array and it's up to the user of the API transform such
 * // arrays into something presentable, with the freedom to deal with
 * // colors and special characters.
 * //
 * // Functions that return an object based on an index may throw
 * // exceptions on for example out-of-bounds.
 *
 * // Demonstration purposes, will botch special chars and colors.
 * const txt = new TextDecoder();
 *
 * const client = Module.getClientState();
 *
 * console.log(client.gametime, client.getLevelName());
 *
 * for (var it = client.getItemTimers(); it != null; it = it.getNext()) {
 *     console.log(it.getTypeName(), "picked up at ", it.getLocation());
 * }
 *
 * console.log(client.getPlayerLocation(3));
 *
 * const player = client.getPlayer(3);
 *
 * // Strings are typed as Uint8Array as they aren't UTF-8 or ASCII.
 * // Deal with remapping frontend side as this will be ugly.
 * console.log(txt.decode(player.getName()), txt.decode(player.getTeam()));
 *
 * // There are "cleaned" versions with special symbols and colors stripped.
 * console.log(player.getTeamPlain(), player.getNamePlain());
 *
 * const stats = client.getStats();
 * console.log(stats[Module.STAT_ARMOR]);

 * const items = stats[Module.STAT_ITEMS];
 * console.log("Has RL", items & Module.IT_ROCKET_LAUNCHER);
 *
 * const rlstats = player.getWeaponStats(Module.W_ROCKET_LAUNCHER);
 * console.log(rlstats.hit, rlstats.total);
 *
 * const fragstats = Module.getFragStats();
 * console.log(fragstats.totalkills);
 *
 * const player_fragstats = fragstats.getClientTotals(3);
 * console.log(player_fragstats.teamkills);
 */

typedef struct entity_mapping_st {
	const char *mdl;
	const char *tp_cvar;
	unsigned int item;
	int skin;
} entity_mapping_t;

static entity_mapping_t entity_mapping[] = {
		{ "progs/backpack.mdl", "tp_name_backpack", 0,                   -1 },
		{ "progs/ring.mdl",     "tp_name_ring",     IT_INVISIBILITY,     -1 },
		{ "progs/invulner.mdl", "tp_name_pent",     IT_INVULNERABILITY,  -1 },
		{ "progs/quaddama.mdl", "tp_name_quad",     IT_QUAD,             -1 },
		{ "progs/suit.mdl",     "tp_name_suit",     IT_SUIT,             -1 },
		{ "progs/armor.mdl",    "tp_name_ra",       IT_ARMOR3,            2 },
		{ "progs/armor.mdl",    "tp_name_ya",       IT_ARMOR2,            1 },
		{ "progs/armor.mdl",    "tp_name_ga",       IT_ARMOR1,            0 },
		{ "progs/g_shot.mdl",   "tp_name_ssg",      IT_SUPER_SHOTGUN,    -1 },
		{ "progs/g_nail.mdl",   "tp_name_ng",       IT_NAILGUN,          -1 },
		{ "progs/g_nail2.mdl",  "tp_name_sng",      IT_SUPER_NAILGUN,    -1 },
		{ "progs/g_rock.mdl",   "tp_name_gl",       IT_GRENADE_LAUNCHER, -1 },
		{ "progs/g_rock2.mdl",  "tp_name_rl",       IT_ROCKET_LAUNCHER,  -1 },
		{ "progs/g_light.mdl",  "tp_name_lg",       IT_LIGHTNING,        -1 },
		{ "maps/b_bh100.bsp",   "tp_name_mh",       IT_SUPERHEALTH,      -1 },
};

static const entity_mapping_t *find_entity(int entnum) {
	entity_state_t *ent;
	const char *mdl;
	int i;

	if (entnum >= cl.maxlerpents || !cl.lerpentssequence || cl.lerpents[entnum].sequence != cl.lerpentssequence) {
		if (entnum >= 0 || entnum < cl_baselines_count) {
			ent = &cl_baselines[entnum];
		} else {
			throw std::out_of_range("itemtimer entity index out of range");
		}
	} else {
		ent = (&cl.lerpents[entnum])->entstate;
	}

	if (ent->modelindex < 0 || ent->modelindex >= MAX_PRECACHE_MODELS)
		throw std::out_of_range("itemtimer entity model index out of range");

	mdl = cl.model_name[ent->modelindex];
	if (!mdl)
		throw std::out_of_range("itemtimer entity model not found");

	for (i = 0; i < countof(entity_mapping); i++) {
		entity_mapping_t *e = &entity_mapping[i];
		if (!strcmp(e->mdl, mdl) && (e->skin == -1 || e->skin == ent->skinnum))
			return e;
	}

	throw std::invalid_argument("itemtimer entity type not supported");
}

static void collect_infobuf(void *ctx, const char *key, const char *value) {
	emscripten::val *result = (emscripten::val *) ctx;
	result->set(key, value);
}

// Standard Quake brush-box items (item_health, item_shells, _spikes,
// _rockets, _cells) call setmodel("maps/b_*.bsp") at runtime; the box
// geometry sits at the +X / +Y corner of the entity origin, so the
// visual center is at origin + (16, 16). Used by both getEntities()
// and highlightEntityIndex() so the web sees a single consistent
// position for marker placement and teleport target.
static bool is_brush_box_item(const char *classname) {
	return !strcmp(classname, "item_health")  ||
	       !strcmp(classname, "item_shells")  ||
	       !strcmp(classname, "item_spikes")  ||
	       !strcmp(classname, "item_rockets") ||
	       !strcmp(classname, "item_cells");
}

// Resolves the effective world position of a BSP entity record.
// Point entities carry their position directly in `origin`. Brush
// entities (trigger_teleport, trigger_hurt, ...) leave origin at
// 0,0,0 and reference a worldmodel submodel via `model "*N"`; for
// those we compute the bbox center from the model_t submodel table.
// Returns true on success.
static bool resolve_bsp_entity_origin(const char *origin_str,
                                      const char *model_str,
                                      float *ox, float *oy, float *oz) {
	float x = 0, y = 0, z = 0;
	int parsed = sscanf(origin_str, "%f %f %f", &x, &y, &z);
	bool origin_present = parsed == 3 && (x != 0 || y != 0 || z != 0);
	if (origin_present) {
		*ox = x; *oy = y; *oz = z;
		return true;
	}
	if (model_str && model_str[0] == '*' && cl.worldmodel &&
	    cl.worldmodel->submodels) {
		int n = atoi(model_str + 1);
		if (n > 0 && n < cl.worldmodel->numsubmodels) {
			mmodel_t *sm = &cl.worldmodel->submodels[n];
			*ox = (sm->mins[0] + sm->maxs[0]) * 0.5f;
			*oy = (sm->mins[1] + sm->maxs[1]) * 0.5f;
			*oz = (sm->mins[2] + sm->maxs[2]) * 0.5f;
			return true;
		}
	}
	if (parsed == 3) {  // origin was explicitly "0 0 0"
		*ox = x; *oy = y; *oz = z;
		return true;
	}
	return false;
}

// Resolves the world origin of the info_teleport_destination whose
// targetname matches `target`. Walks the BSP entity string once. Returns
// true on hit (and writes ox/oy/oz); false when no destination has that
// targetname or no map is loaded. Used by getEntities() to surface the
// destination's loc_name on each trigger_teleport entry so the web app
// can show "from X to Y" without doing the lookup client-side.
static bool find_teleport_destination_origin(const char *target,
                                             float *ox, float *oy, float *oz) {
	if (!target || !target[0]) return false;
	if (!cl.worldmodel) return false;
	const char *ents = Mod_GetEntitiesString(cl.worldmodel);
	if (!ents) return false;
	char token[1024];
	while (ents && *ents) {
		ents = COM_ParseOut(ents, token, sizeof(token));
		if (token[0] != '{') continue;
		char classname[128]        = "";
		char origin_str[128]       = "";
		char model_field[128]      = "";
		char targetname_field[128] = "";
		while (ents && *ents) {
			ents = COM_ParseOut(ents, token, sizeof(token));
			if (token[0] == '}') break;
			char value[1024];
			ents = COM_ParseOut(ents, value, sizeof(value));
			if      (!strcmp(token, "classname"))  Q_strncpyz(classname,        value, sizeof(classname));
			else if (!strcmp(token, "origin"))     Q_strncpyz(origin_str,       value, sizeof(origin_str));
			else if (!strcmp(token, "model"))      Q_strncpyz(model_field,      value, sizeof(model_field));
			else if (!strcmp(token, "targetname")) Q_strncpyz(targetname_field, value, sizeof(targetname_field));
		}
		if (strcmp(classname, "info_teleport_destination")) continue;
		if (strcmp(targetname_field, target))               continue;
		return resolve_bsp_entity_origin(origin_str, model_field, ox, oy, oz);
	}
	return false;
}

static lerpents_t* get_player_lerped(int index) {
	if (index + 1 < cl.maxlerpents && cl.lerpentssequence && cl.lerpents[index + 1].sequence == cl.lerpentssequence)
		return &cl.lerpents[index + 1];
	if (cl.lerpentssequence && cl.lerpplayers[index].sequence == cl.lerpentssequence)
		return &cl.lerpplayers[index];
	throw std::out_of_range("Player index out of range");
}

EMSCRIPTEN_BINDINGS(browser_api) {
	constant("STAT_HEALTH",         (int) STAT_HEALTH        );
	constant("STAT_WEAPONMODELI",   (int) STAT_WEAPONMODELI  );
	constant("STAT_AMMO",           (int) STAT_AMMO          );
	constant("STAT_ARMOR",          (int) STAT_ARMOR         );
	constant("STAT_WEAPONFRAME",    (int) STAT_WEAPONFRAME   );
	constant("STAT_SHELLS",         (int) STAT_SHELLS        );
	constant("STAT_NAILS",          (int) STAT_NAILS         );
	constant("STAT_ROCKETS",        (int) STAT_ROCKETS       );
	constant("STAT_CELLS",          (int) STAT_CELLS         );
	constant("STAT_ACTIVEWEAPON",   (int) STAT_ACTIVEWEAPON  );
	constant("STAT_TOTALSECRETS",   (int) STAT_TOTALSECRETS  );
	constant("STAT_TOTALMONSTERS",  (int) STAT_TOTALMONSTERS );
	constant("STAT_SECRETS",        (int) STAT_SECRETS       );
	constant("STAT_MONSTERS",       (int) STAT_MONSTERS      );
	constant("STAT_ITEMS",          (int) STAT_ITEMS         );
	constant("STAT_VIEWHEIGHT",     (int) STAT_VIEWHEIGHT    );
	constant("STAT_TIME",           (int) STAT_TIME          );
	constant("STAT_MATCHSTARTTIME", (int) STAT_MATCHSTARTTIME);

	constant("W_AXE",              0);
	constant("W_SHOTGUN",          1);
	constant("W_SUPER_SHOTGUN",    2);
	constant("W_NAILGUN",          3);
	constant("W_SUPER_NAILGUN",    4);
	constant("W_GRENADE_LAUNCHER", 5);
	constant("W_ROCKET_LAUNCHER",  6);
	constant("W_LIGHTNING",        7);

	constant("IT_SHOTGUN",          (int) IT_SHOTGUN         );
	constant("IT_SUPER_SHOTGUN",    (int) IT_SUPER_SHOTGUN   );
	constant("IT_NAILGUN",          (int) IT_NAILGUN         );
	constant("IT_SUPER_NAILGUN",    (int) IT_SUPER_NAILGUN   );
	constant("IT_GRENADE_LAUNCHER", (int) IT_GRENADE_LAUNCHER);
	constant("IT_ROCKET_LAUNCHER",  (int) IT_ROCKET_LAUNCHER );
	constant("IT_LIGHTNING",        (int) IT_LIGHTNING       );
	constant("IT_SUPER_LIGHTNING",  (int) IT_SUPER_LIGHTNING );
	constant("IT_SHELLS",           (int) IT_SHELLS          );
	constant("IT_NAILS",            (int) IT_NAILS           );
	constant("IT_ROCKETS",          (int) IT_ROCKETS         );
	constant("IT_CELLS",            (int) IT_CELLS           );
	constant("IT_AXE",              (int) IT_AXE             );
	constant("IT_ARMOR1",           (int) IT_ARMOR1          );
	constant("IT_ARMOR2",           (int) IT_ARMOR2          );
	constant("IT_ARMOR3",           (int) IT_ARMOR3          );
	constant("IT_SUPERHEALTH",      (int) IT_SUPERHEALTH     );
	constant("IT_KEY1",             (int) IT_KEY1            );
	constant("IT_KEY2",             (int) IT_KEY2            );
	constant("IT_INVISIBILITY",     (int) IT_INVISIBILITY    );
	constant("IT_INVULNERABILITY",  (int) IT_INVULNERABILITY );
	constant("IT_SUIT",             (int) IT_SUIT            );
	constant("IT_QUAD",             (int) IT_QUAD            );
	constant("IT_SIGIL1",           (int) IT_SIGIL1          );
	constant("IT_SIGIL2",           (int) IT_SIGIL2          );
	constant("IT_SIGIL3",           (int) IT_SIGIL3          );
	constant("IT_SIGIL4",           (int) IT_SIGIL4          );

	class_<player_info_t::wstats_s>("WeaponStats")
		.property("hit", &player_info_t::wstats_s::hit)
		.property("total", &player_info_t::wstats_s::total)
		.function("getName", +[](struct player_info_t::wstats_s& self) -> emscripten::val {
			size_t len = strnlen(self.wname, 16);
			return val(typed_memory_view(len, (unsigned char*) self.wname));
		});

	class_<player_info_t>("PlayerInfo")
		.property("userid", &player_info_t::userid)
		.property("spectator", &player_info_t::spectator)
		.property("frags", &player_info_t::frags)
		.property("topcolor", &player_info_t::rtopcolor)
		.property("bottomcolor", &player_info_t::rbottomcolor)
		.function("getName", +[](player_info_t& self) -> emscripten::val {
			size_t len = strnlen(self.name, MAX_SCOREBOARDNAME);
			return val(typed_memory_view(len, (unsigned char *) self.name));
		})
		.function("getNamePlain", +[](player_info_t& self) -> std::string {
			conchar_t buffer[MAX_SCOREBOARDNAME];
			char out[MAX_SCOREBOARDNAME];
			COM_ParseFunString(CON_WHITEMASK, self.name, buffer, sizeof(buffer), qfalse);
			COM_DeFunString(buffer, NULL, out, sizeof(out), qtrue, qfalse);
			return std::string(out);
		})
		.function("getTeam", +[](player_info_t& self) -> emscripten::val {
			size_t len = strnlen(self.team, MAX_INFO_KEY);
			return val(typed_memory_view(len, (unsigned char *) self.team));
		})
		.function("getTeamPlain", +[](player_info_t& self) -> std::string {
			conchar_t buffer[MAX_INFO_KEY];
			char out[MAX_INFO_KEY];
			COM_ParseFunString(CON_WHITEMASK, self.team, buffer, sizeof(buffer), qfalse);
			COM_DeFunString(buffer, NULL, out, sizeof(out), qtrue, qfalse);
			return std::string(out);
		})
		.function("getWeaponStats", +[](player_info_t& self, size_t index) -> struct player_info_s::wstats_s * {
			if (index < 0 && index >= 16)
				throw std::out_of_range("Weapon index out of range");
			return &(self.weaponstats[index]);
		}, allow_raw_pointers())
		.function("getStats", +[](player_info_t& self) -> emscripten::val {
			return val(typed_memory_view(MAX_QW_STATS, self.stats));
		})
		.function("getStatsFloat", +[](player_info_t& self) -> emscripten::val {
			return val(typed_memory_view(MAX_QW_STATS, self.statsf));
		})
		.function("getLocation", +[](player_info_t& self) -> std::string {
			lerpents_t *le = get_player_lerped(&self - cl.players);
			const char *location = TP_LocationName(le->origin);
			if (location != NULL)
				return std::string(location);
			return std::string("unknown");
		})
		.function("getOrigin", +[](player_info_t& self) -> emscripten::val {
			lerpents_t *le = get_player_lerped(&self - cl.players);
			emscripten::val origin = emscripten::val::object();
			origin.set("x", le->origin[0]);
			origin.set("y", le->origin[1]);
			origin.set("z", le->origin[2]);
			return origin;
		})
		.function("getAngles", +[](player_info_t& self) -> emscripten::val {
			lerpents_t *le = get_player_lerped(&self - cl.players);
			emscripten::val angles = emscripten::val::object();
			angles.set("pitch", le->angles[0]);
			angles.set("yaw", le->angles[1]);
			return angles;
		})
		.function("getUserInfo", +[](player_info_t& self) -> emscripten::val {
			emscripten::val result = emscripten::val::object();
			if (self.userinfovalid) {
				InfoBuf_Enumerate(&self.userinfo, &result, collect_infobuf);
			}
			return result;
		})
		.function("setUserInfo", +[](player_info_t& self, emscripten::val jskey, emscripten::val jsvalue) -> emscripten::val {
			const std::string key = jskey.as<std::string>();
			const std::string value = jsvalue.as<std::string>();
			bool result = InfoBuf_SetKey(&self.userinfo, key.c_str(), value.c_str());
			return emscripten::val(result);

		}, allow_raw_pointers());

	class_<client_state_t::itemtimer_s>("ItemTimer")
		.property("start", &client_state_t::itemtimer_s::start)
		.property("end", &client_state_t::itemtimer_s::end)
		.property("entnum", &client_state_t::itemtimer_s::entnum)
		.property("duration", &client_state_t::itemtimer_s::duration)
		.property("radius", &client_state_t::itemtimer_s::radius)
		.function("getType", +[](client_state_t::itemtimer_s& self) -> unsigned int {
			const entity_mapping_t *e = find_entity(self.entnum);
			return e->item;
		})
		.function("getTypeName", +[](client_state_t::itemtimer_s& self) -> std::string {
			const entity_mapping_t *e = find_entity(self.entnum);
			cvar_t *c = Cvar_FindVar(e->tp_cvar);
			if (!c)
				throw std::invalid_argument("itemtimer entity type not supported");
			return std::string(c->string);
		})
		.function("getLocation", +[](client_state_t::itemtimer_s& self) -> std::string {
			const char *location = TP_LocationName(self.origin);
			if (location != NULL)
				return std::string(location);
			return std::string("unknown");
		})
		.function("getNext", +[](client_state_t::itemtimer_s& self) -> client_state_t::itemtimer_s* {
			return self.next;
		}, allow_raw_pointers());

	class_<playerview_t>("PlayerView")
	        .property("playernum", &playerview_t::playernum)
			.property("cam_spec_track", &playerview_t::cam_spec_track)
			.function("getTrackedPlayer", +[](playerview_t& self) -> player_info_t* {
				return &(cl.players[self.cam_spec_track]);
			}, allow_raw_pointers());

	class_<client_state_t>("ClientState")
		// .property("deathmatch", &client_state_t::deathmatch)
		// .property("teamplay", &client_state_t::teamplay)
		.property("allocated_client_slots", &client_state_t::allocated_client_slots)
		.property("matchstate", &client_state_t::matchstate) // enum, how
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

			int elapsed_ms  = Hub_GetDemoElapsedMs();
			if (elapsed_ms <= 0)
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
		.function("getItemTimer", +[](client_state_t& self) -> client_state_t::itemtimer_s* {
			return self.itemtimers;
		}, allow_raw_pointers())
		.function("getItemTimers", +[](client_state_t& self) -> emscripten::val {
			emscripten::val result = emscripten::val::array();
			int n_timer = 0;
			for (client_state_t::itemtimer_s *it = cl.itemtimers; it != NULL; it = it->next) {
				result.set(n_timer++, it);
			}
			return result;
		}, allow_raw_pointers())
		.function("getPlayer", +[](client_state_t& self, size_t index) -> player_info_t* {
			if (index < 0 && index >= MAX_CLIENTS)
				throw std::out_of_range("Player index out of range");
			return &(self.players[index]);
		}, allow_raw_pointers())
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
		}, allow_raw_pointers())
		.function("getPlayerView", +[](client_state_t& self, size_t index) -> playerview_t* {
			if (index >= cl.splitclients) {
				throw std::out_of_range("Player view index out of range");
			}
			return &(cl.playerview[index]);
		}, allow_raw_pointers())
		.function("getPlayerViews", +[](client_state_t& self) -> emscripten::val {
			emscripten::val result = emscripten::val::array();
			int n_player = 0;
			for (int i = 0; i < cl.splitclients; i++) {
				playerview_t *pv = &(cl.playerview[i]);
				result.set(n_player++, pv);
			}
			return result;
		}, allow_raw_pointers())
		.function("getServerInfo", +[](client_state_t& self) -> emscripten::val {
			extern cvar_t host_mapname;
			if (cls.state == ca_disconnected) {
				return emscripten::val::null();
			}
			emscripten::val result = emscripten::val::object();
			if (self.haveserverinfo) {
				InfoBuf_Enumerate(&self.serverinfo, &result, collect_infobuf);
			}
			if (result["timelimit"].isUndefined()) {
				result.set("timelimit", "0");
			}
			if (!result["maxclients"].isUndefined()) {
				result.set("maxclients", atoi(result["maxclients"].as<std::string>().c_str()));
			}
			if (!result["hostname"].isUndefined()) {
				std::string hostname = result["hostname"].as<std::string>();
				const std::string needle = " (live: ";
				size_t pos = hostname.find(needle);
				if (pos != std::string::npos && !hostname.empty() && hostname.back() == ')') {
					hostname = hostname.substr(pos + needle.size(), hostname.size() - pos - needle.size() - 1);
					result.set("hostname", hostname);
				}
			}
			result.set("map", std::string(host_mapname.string));
			result.set("deathmatch", (int) self.deathmatch);
			result.set("teamplay", (int) self.teamplay);
			result.set("is_netquake", cls.protocol == client_static_t::CP_NETQUAKE);
			return result;
		}, allow_raw_pointers());

	function("getClientState", +[]() -> client_state_t* {
		return &cl;
	}, allow_raw_pointers());

	class_<fragstats_t::wt_s>("WeaponTotals")
		.property("kills", &fragstats_t::wt_s::kills)
		.property("teamkills", &fragstats_t::wt_s::teamkills)
		.property("suicides", &fragstats_t::wt_s::suicides)
		.property("ownkills", &fragstats_t::wt_s::ownkills)
		.property("owndeaths", &fragstats_t::wt_s::owndeaths)
		.property("ownteamkills", &fragstats_t::wt_s::ownteamkills)
		.property("ownteamdeaths", &fragstats_t::wt_s::ownteamdeaths)
		.property("ownsuicides", &fragstats_t::wt_s::ownsuicides)
		.function("getName", +[](fragstats_t::wt_s& self) {
			return std::string(self.fullname);
		})
		.function("getAbbreviation", +[](fragstats_t::wt_s& self) {
			return std::string(self.abrev);
		})
		.function("getImage", +[](fragstats_t::wt_s& self) {
			return std::string(self.image);
		})
		.function("getCodeName", +[](fragstats_t::wt_s& self) {
			return std::string(self.codename);
		});

	class_<fragstats_t::ct_s>("ClientTotals")
		.property("caps", &fragstats_t::ct_s::caps)
		.property("drops", &fragstats_t::ct_s::drops)
		.property("grabs", &fragstats_t::ct_s::grabs)
		.property("owndeaths", &fragstats_t::ct_s::owndeaths)
		.property("ownkills", &fragstats_t::ct_s::ownkills)
		.property("deaths", &fragstats_t::ct_s::deaths)
		.property("kills", &fragstats_t::ct_s::kills)
		.property("teamkills", &fragstats_t::ct_s::teamkills)
		.property("teamdeaths", &fragstats_t::ct_s::teamdeaths)
		.property("suicides", &fragstats_t::ct_s::suicides);

	class_<fragstats_t>("FragStats")
		.property("totaldeaths", &fragstats_t::totaldeaths)
		.property("totalsuicides", &fragstats_t::totalsuicides)
		.property("totalteamkills", &fragstats_t::totalteamkills)
		.property("totalkills", &fragstats_t::totalkills)
		.property("totaltouches", &fragstats_t::totaltouches)
		.property("totalcaps", &fragstats_t::totalcaps)
		.property("totaldrops", &fragstats_t::totaldrops)
		.function("getWeaponTotals", +[](fragstats_t& self, size_t index) -> struct fragstats_t::wt_s * {
			if (index < 0 && index >= MAX_WEAPONS)
				throw std::out_of_range("Weapon index out of range");
			return &(self.weapontotals[index]);
		}, allow_raw_pointers())
		.function("getClientTotals", +[](fragstats_t& self, size_t index) -> struct fragstats_t::ct_s * {
			if (index < 0 && index >= MAX_CLIENTS)
				throw std::out_of_range("Client index out of range");
			return &(self.clienttotals[index]);
		}, allow_raw_pointers());

	function("getFragStats", +[]() -> fragstats_t* {
		extern fragstats_t fragstats;
		return &fragstats;
	}, allow_raw_pointers());

	function("getConnectionInfo", +[]() -> emscripten::val {
        emscripten::val info = emscripten::val::object();

        // ca_disconnected // full screen console with no connection
		// ca_demostart // waiting to start up a demo (still disconnected but there should be a playdemo command in the cbuf somewhere so don't do other stuff)
		// ca_connected // netchan_t established, waiting for svc_serverdata
		// ca_onserver // processing data lists, donwloading, etc
		// ca_active // everything is in, so frames can be rendered

		// disconnected
        if (cls.state == ca_disconnected) {
            info.set("state", "disconnected");
            return info;
        }

        // connected
        // state: "connected";
        // phase: "connecting" | "active";
        // type: "server" | "demo" | "qtv";
        // last_source: string; // qtv stream or demo url
        info.set("state", "connected");

        if (cls.state == ca_active) {
            info.set("phase", "active");
        } else {
            info.set("phase", "connecting");
        }

        if (cls.demoplayback) {
           	if (*cls.lastdemoname) {
                info.set("type", "demo");
				info.set("last_source", cls.lastdemoname);
           	} else {
                info.set("type", "qtv");
                info.set("last_source", cls.last_qtv_stream);
            }
       	} else {
            info.set("type", "server");
            info.set("last_source", "localhost");
        }

        return info;
	});

	function("getCvar", +[](std::string name) -> std::string {
		return std::string(Cvar_VariableString(name.c_str()));
	});

	// Bridge from the web app to the CSQC minimap overlay. Writes a
	// "X Y Z" string to the minimap_highlight cvar; the addon's
	// MinimapRender reads it each frame and projects the coord onto the
	// minimap (see hub_addon/src/minimap.qc). Pass NaN/empty equivalent
	// via clearMinimapHighlight() to remove the marker.
	function("setMinimapHighlight", +[](double x, double y, double z) {
		// Default marker style (yellow stroked disc, radius 8,
		// angle 0) emitted as the 9-token-per-point format CSQC
		// consumes. "disc" uses MinimapDrawRing -> drawline, which
		// rasterizes reliably at any size; the filled "dot" shape
		// collapses to sub-pixel triangle fans at small radii.
		//
		// Does NOT auto-enable the minimap (unlike setMinimapHeatmap /
		// highlightEntityIndex). Callers that want the highlight to be
		// visible must set minimap_mode themselves first.
		char buf[96];
		snprintf(buf, sizeof(buf), "%g %g %g disc 8 1 1 0 0", x, y, z);
		Cvar_Set(Cvar_FindVar("minimap_highlight"), buf);
	});

	function("clearMinimapHighlight", +[]() {
		Cvar_Set(Cvar_FindVar("minimap_highlight"), "");
	});

	// Heatmap: an array of 2D world points rendered on top of the
	// minimap as accumulating heat blobs. Each entry is read as
	// { x: number, y: number } (z ignored - the minimap is top-down).
	// Serialized to the minimap_heatmap cvar as "x0 y0 x1 y1 ...";
	// the CSQC side (hub_addon/src/minimap.qc) tokenizes and draws.
	// Pass an empty array (or call clearMinimapHeatmap) to remove it.
	//
	// The optional second arg is a config object that hot-tweaks the
	// heatmap look without rebuilding the wasm. Recognized keys
	// (each optional; unspecified keys leave the current cvar alone):
	//   radius    -> minimap_heatmap_radius     (world units, blob size)
	//   intensity -> minimap_heatmap_intensity  (0..1, per-blob alpha)
	//   falloff   -> minimap_heatmap_falloff    (Gaussian sharpness; higher = less bleed)
	// Pass undefined / {} to keep the existing values.
	//
	// Side effect: when the input is non-empty and minimap_mode == 0
	// (minimap off), flip it to MINIMAP_SPLIT (2) so the heatmap is
	// actually visible. Any other mode is left alone. Caller doesn't
	// need to know about minimap_mode to make the heatmap show up.
	function("setMinimapHeatmap", +[](emscripten::val points, emscripten::val config) {
		auto apply_cvar = [&](const char *key, const char *cvar_name) {
			emscripten::val v = config[key];
			if (v.isUndefined() || v.isNull()) return;
			char buf[32];
			snprintf(buf, sizeof(buf), "%g", v.as<double>());
			Cvar_Set(Cvar_FindVar(cvar_name), buf);
		};
		if (!config.isUndefined() && !config.isNull()) {
			apply_cvar("radius",    "minimap_heatmap_radius");
			apply_cvar("intensity", "minimap_heatmap_intensity");
			apply_cvar("falloff",   "minimap_heatmap_falloff");
		}

		std::string serialized;
		serialized.reserve(64 * 16);
		int n = points["length"].as<int>();
		for (int i = 0; i < n; i++) {
			emscripten::val p = points[i];
			double x = p["x"].as<double>();
			double y = p["y"].as<double>();
			char buf[64];
			snprintf(buf, sizeof(buf), "%s%g %g",
			         i == 0 ? "" : " ", x, y);
			serialized += buf;
		}
		Cvar_Set(Cvar_FindVar("minimap_heatmap"), serialized.c_str());
		// Does NOT auto-enable the minimap. Callers that want it
		// visible must set minimap_mode themselves first (parity with
		// setMinimapHighlight / highlightEntityIndex).
	});

	function("clearMinimapHeatmap", +[]() {
		Cvar_Set(Cvar_FindVar("minimap_heatmap"), "");
	});

	function("getMacroValue", +[](std::string name) -> std::string {
		char *value = Cmd_GetMacroValue(name.c_str());
		return value ? std::string(value) : std::string("");
	});

	function("getMapName", +[]() -> std::string {
		extern cvar_t host_mapname;
        return std::string(host_mapname.string);
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

	// Lock the spectator camera in `seat` (0-based) onto the player whose
	// userid matches `userid`. Pass userid as a numeric string ("1234") or
	// the literal "off" to release. Routed directly to Hub_TrackPlayerByUserid
	// so callers don't have to construct a cbuf command. Used by the web
	// app's scoreboard click handler; the CSQC player_info widget uses its
	// own console-command path.
	function("trackPlayerByUserid", +[](int seat, std::string userid) {
		Hub_TrackPlayerByUserid(seat, const_cast<char *>(userid.c_str()));
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

	// Enumerate every entity defined in the currently-loaded map's BSP
	// entity string (cl.worldmodel->entities_raw). Each entry is
	//   { classname, spawnflags, origin: {x, y, z} }
	// classname is the QC entity classname (e.g. "item_armor1",
	// "weapon_rocketlauncher", "item_health"); spawnflags lets the
	// caller distinguish variants (e.g. mega health = item_health
	// with spawnflags & 2). Empty array when no map is loaded.
	//
	// Sourced from the BSP itself, not the network state - works
	// uniformly across demo playback, local listen server (`+map`),
	// and live connection. Independent of cl_baselines being
	// populated.
	function("getEntities", +[]() -> emscripten::val {
		emscripten::val result = emscripten::val::array();
		if (!cl.worldmodel) return result;
		const char *ents = Mod_GetEntitiesString(cl.worldmodel);
		if (!ents) return result;

		// Ensure the map pack (the pak/pk3 containing the BSP) is
		// registered with the FS. Custom maps ship their .loc inside
		// that same pack, and FS_LoadMapPackFile runs in a later
		// cl_parse stage than the one that sets cl.worldmodel - so
		// without this an early getEntities() can't find the .loc
		// even though the file is right there. Idempotent
		// (FS_MapPackIsActive short-circuit), so calling it on every
		// getEntities() is cheap. Then force-load the .loc and pin
		// cls.state = ca_active for the duration so TP_LocationName
		// doesn't bail with "someplace".
		if (cl.worldmodel && cl.worldmodel->archive)
			FS_LoadMapPackFile(cl.worldmodel->name, cl.worldmodel->archive);
		TP_ReloadCurrentLocs();
		cactive_t saved_state = cls.state;
		cls.state = ca_active;

		int out_idx = 0;
		char token[1024];
		while (ents && *ents) {
			ents = COM_ParseOut(ents, token, sizeof(token));
			if (token[0] != '{') continue;

			char  classname[128]        = "";
			char  origin_str[128]       = "";
			char  model_field[128]      = "";
			char  target_field[128]     = "";
			char  targetname_field[128] = "";
			int   spawnflags            = 0;
			float angle_field           = 0;
			while (ents && *ents) {
				ents = COM_ParseOut(ents, token, sizeof(token));
				if (token[0] == '}') break;
				char value[1024];
				ents = COM_ParseOut(ents, value, sizeof(value));
				if (!strcmp(token, "classname"))
					Q_strncpyz(classname, value, sizeof(classname));
				else if (!strcmp(token, "origin"))
					Q_strncpyz(origin_str, value, sizeof(origin_str));
				else if (!strcmp(token, "model"))
					Q_strncpyz(model_field, value, sizeof(model_field));
				else if (!strcmp(token, "target"))
					Q_strncpyz(target_field, value, sizeof(target_field));
				else if (!strcmp(token, "targetname"))
					Q_strncpyz(targetname_field, value,
					           sizeof(targetname_field));
				else if (!strcmp(token, "spawnflags"))
					spawnflags = atoi(value);
				else if (!strcmp(token, "angle"))
					angle_field = (float)atof(value);
				else if (!strcmp(token, "angles")) {
					float pitch, yaw, roll;
					if (sscanf(value, "%f %f %f",
					           &pitch, &yaw, &roll) == 3)
						angle_field = yaw;
				}
			}
			if (!classname[0]) continue;

			float ox = 0, oy = 0, oz = 0;
			// resolve_bsp_entity_origin handles both point entities
			// (uses origin as-is) and brush entities like
			// trigger_teleport (computes the submodel bbox center
			// since origin is "0 0 0" in the BSP entity string).
			resolve_bsp_entity_origin(origin_str, model_field,
			                          &ox, &oy, &oz);
			// Brush-box items render with their geometry shifted to
			// the +X / +Y corner of the entity origin. Surface the
			// visual center so the web's marker placement and the
			// click-to-teleport target both land on what the user
			// actually sees on the minimap.
			if (is_brush_box_item(classname)) {
				ox += 16;
				oy += 16;
			}

			// Resolve the entity's world position to a .loc zone name.
			// Empty string when no .loc is loaded or the point isn't
			// inside any zone (TP_LocationName returns "someplace" in
			// that case - prefer "" so the consumer can decide how to
			// render the fallback).
			auto resolve_loc = [](float x, float y, float z) -> std::string {
				vec3_t p = { x, y, z };
				const char *l = TP_LocationName(p);
				return (l && strcmp(l, "someplace")) ?
				    std::string(l) : std::string();
			};
			std::string loc_name = resolve_loc(ox, oy, oz);

			// Teleporter destination loc: only meaningful on
			// trigger_teleport (entrance). info_teleport_destination
			// entries already carry their own loc_name in the same
			// field, no need to chase a non-existent "next" hop.
			std::string destination_loc_name;
			if (!strcmp(classname, "trigger_teleport") &&
			    target_field[0]) {
				float dx = 0, dy = 0, dz = 0;
				if (find_teleport_destination_origin(target_field,
				                                     &dx, &dy, &dz)) {
					destination_loc_name = resolve_loc(dx, dy, dz);
				}
			}

			emscripten::val e = emscripten::val::object();
			e.set("id",                   out_idx);
			e.set("classname",            std::string(classname));
			e.set("spawnflags",           spawnflags);
			e.set("target",               std::string(target_field));
			e.set("targetname",           std::string(targetname_field));
			e.set("angle",                angle_field);
			e.set("loc_name",             loc_name);
			e.set("destination_loc_name", destination_loc_name);
			emscripten::val origin = emscripten::val::object();
			origin.set("x", ox);
			origin.set("y", oy);
			origin.set("z", oz);
			e.set("origin", origin);
			result.set(out_idx++, e);
		}
		cls.state = saved_state;
		return result;
	});

	// Set the CSQC minimap highlight to the world position of the
	// entity at iteration index `id` (same id field getEntities()
	// returns). For teleporters (trigger_teleport / info_teleport_-
	// destination) the linked partner is highlighted too via the
	// target/targetname relationship - the cvar format supports
	// multiple "x y z" triplets that the CSQC renders together and
	// draws a dotted connector between consecutive points. No-op
	// for out-of-range id or no map.
	function("highlightEntityIndex", +[](int id, emscripten::val marker_val) {
		// Marker style defaults match the legacy yellow dot. Caller
		// can override via { shape: "dot"|"ring", size: number,
		// color: "#RRGGBB" }; missing fields fall back to defaults.
		std::string shape = "dot";
		double size = 4.0;
		double mr = 1.0, mg = 1.0, mb = 0.0;
		if (!marker_val.isUndefined() && !marker_val.isNull()) {
			emscripten::val v_shape = marker_val["shape"];
			emscripten::val v_size  = marker_val["size"];
			emscripten::val v_color = marker_val["color"];
			if (!v_shape.isUndefined())
				shape = v_shape.as<std::string>();
			if (!v_size.isUndefined())
				size = v_size.as<double>();
			if (!v_color.isUndefined()) {
				std::string hex = v_color.as<std::string>();
				if (hex.size() == 7 && hex[0] == '#') {
					int r, g, b;
					if (sscanf(hex.c_str() + 1, "%2x%2x%2x",
					           &r, &g, &b) == 3) {
						mr = r / 255.0;
						mg = g / 255.0;
						mb = b / 255.0;
					}
				}
			}
		}
		if (id < 0) return;
		if (!cl.worldmodel) return;
		const char *ents0 = Mod_GetEntitiesString(cl.worldmodel);
		if (!ents0) return;

		// Pass 1: find the entity at index `id` and capture the
		// fields we need (classname + origin + model + target/
		// targetname for the teleporter-pair lookup).
		char  target_classname[128]  = "";
		char  target_origin_str[128] = "";
		char  target_model[128]      = "";
		char  target_target[128]     = "";
		char  target_targetname[128] = "";
		float target_angle           = 0;
		bool found = false;
		int  idx   = 0;
		const char *ents = ents0;
		char token[1024];
		while (ents && *ents) {
			ents = COM_ParseOut(ents, token, sizeof(token));
			if (token[0] != '{') continue;
			char  classname[128]        = "";
			char  origin_str[128]       = "";
			char  model_field[128]      = "";
			char  target_field[128]     = "";
			char  targetname_field[128] = "";
			float angle_field           = 0;
			while (ents && *ents) {
				ents = COM_ParseOut(ents, token, sizeof(token));
				if (token[0] == '}') break;
				char value[1024];
				ents = COM_ParseOut(ents, value, sizeof(value));
				if (!strcmp(token, "classname"))
					Q_strncpyz(classname, value, sizeof(classname));
				else if (!strcmp(token, "origin"))
					Q_strncpyz(origin_str, value, sizeof(origin_str));
				else if (!strcmp(token, "model"))
					Q_strncpyz(model_field, value, sizeof(model_field));
				else if (!strcmp(token, "target"))
					Q_strncpyz(target_field, value, sizeof(target_field));
				else if (!strcmp(token, "targetname"))
					Q_strncpyz(targetname_field, value,
					           sizeof(targetname_field));
				else if (!strcmp(token, "angle"))
					angle_field = (float)atof(value);
				else if (!strcmp(token, "angles")) {
					// "pitch yaw roll" - yaw is index 1.
					float pitch, yaw, roll;
					if (sscanf(value, "%f %f %f",
					           &pitch, &yaw, &roll) == 3)
						angle_field = yaw;
				}
			}
			if (!classname[0]) continue;
			if (idx == id) {
				Q_strncpyz(target_classname,  classname,
				           sizeof(target_classname));
				Q_strncpyz(target_origin_str, origin_str,
				           sizeof(target_origin_str));
				Q_strncpyz(target_model,      model_field,
				           sizeof(target_model));
				Q_strncpyz(target_target,     target_field,
				           sizeof(target_target));
				Q_strncpyz(target_targetname, targetname_field,
				           sizeof(target_targetname));
				target_angle = angle_field;
				found = true;
				break;
			}
			idx++;
		}
		if (!found) return;

		// Teleporter pair lookup. Entrance links to destination via
		// `target` -> partner.targetname; reverse direction works
		// the other way. Other entity classes get a single
		// highlight only.
		bool match_via_target     = false;
		bool match_via_targetname = false;
		if (!strcmp(target_classname, "trigger_teleport") &&
		    target_target[0]) {
			match_via_target = true;
		} else if (!strcmp(target_classname, "info_teleport_destination") &&
		           target_targetname[0]) {
			match_via_targetname = true;
		}

		// Required partner classname: clicking the destination looks
		// for the entrance brush; clicking the entrance looks for the
		// destination point. Filtering here prevents an unrelated
		// entity (door, button, train) that happens to share the
		// targetname/target string from being picked first - the
		// failure mode the symmetric search hit on maps where the
		// teleporter target is reused.
		const char *expected_partner_classname =
		    match_via_target           ? "info_teleport_destination" :
		    match_via_targetname       ? "trigger_teleport"          : NULL;

		char  partner_origin_str[128] = "";
		char  partner_model[128]      = "";
		float partner_angle           = 0;
		bool  partner_found           = false;
		if (expected_partner_classname) {
			const char *ents2 = ents0;
			while (ents2 && *ents2) {
				ents2 = COM_ParseOut(ents2, token, sizeof(token));
				if (token[0] != '{') continue;
				char  classname_field[128]  = "";
				char  origin_str[128]       = "";
				char  model_field[128]      = "";
				char  target_field[128]     = "";
				char  targetname_field[128] = "";
				float angle_field           = 0;
				while (ents2 && *ents2) {
					ents2 = COM_ParseOut(ents2, token, sizeof(token));
					if (token[0] == '}') break;
					char value[1024];
					ents2 = COM_ParseOut(ents2, value, sizeof(value));
					if (!strcmp(token, "classname"))
						Q_strncpyz(classname_field, value,
						           sizeof(classname_field));
					else if (!strcmp(token, "origin"))
						Q_strncpyz(origin_str, value, sizeof(origin_str));
					else if (!strcmp(token, "model"))
						Q_strncpyz(model_field, value, sizeof(model_field));
					else if (!strcmp(token, "target"))
						Q_strncpyz(target_field, value,
						           sizeof(target_field));
					else if (!strcmp(token, "targetname"))
						Q_strncpyz(targetname_field, value,
						           sizeof(targetname_field));
					else if (!strcmp(token, "angle"))
						angle_field = (float)atof(value);
					else if (!strcmp(token, "angles")) {
						float pitch, yaw, roll;
						if (sscanf(value, "%f %f %f",
						           &pitch, &yaw, &roll) == 3)
							angle_field = yaw;
					}
				}
				if (strcmp(classname_field, expected_partner_classname))
					continue;
				bool hit = (match_via_target &&
				            !strcmp(targetname_field, target_target)) ||
				           (match_via_targetname &&
				            !strcmp(target_field, target_targetname));
				if (hit) {
					Q_strncpyz(partner_origin_str, origin_str,
					           sizeof(partner_origin_str));
					Q_strncpyz(partner_model, model_field,
					           sizeof(partner_model));
					partner_angle = angle_field;
					partner_found = true;
					break;
				}
			}
		}

		float ox = 0, oy = 0, oz = 0;
		resolve_bsp_entity_origin(target_origin_str, target_model, &ox, &oy, &oz);
		if (is_brush_box_item(target_classname)) {
			ox += 16;
			oy += 16;
		}
		// Per-point format: x y z shape size r g b angle (9 tokens).
		// Both endpoints share the marker style. `angle` is the
		// entity's yaw in degrees (0 for entities with no angle
		// field) - used by the CSQC arrow renderer to orient the
		// arrowhead at the destination toward the player's facing
		// direction after teleport. CSQC parses groups of 9 and
		// draws the line + arrow between consecutive points.
		//
		// Override the caller-supplied shape to "spawn" for player
		// spawn classes (info_player_deathmatch, _start, _coop,
		// _team1, _team2, ...). The CSQC side renders that shape as
		// a disc PLUS an arrow oriented at the entity's yaw so the
		// minimap shows which way the player will face when they
		// spawn here. A plain "dot" loses that information.
		if (!strncmp(target_classname, "info_player_", 12))
			shape = "spawn";
		char buf[512];
		const char *s = shape.c_str();
		if (partner_found) {
			float px = 0, py = 0, pz = 0;
			if (resolve_bsp_entity_origin(partner_origin_str, partner_model,
			                   &px, &py, &pz)) {
				bool target_is_entrance =
				    !strcmp(target_classname, "trigger_teleport");
				float ax = target_is_entrance ? ox : px;
				float ay = target_is_entrance ? oy : py;
				float az = target_is_entrance ? oz : pz;
				float bx = target_is_entrance ? px : ox;
				float by = target_is_entrance ? py : oy;
				float bz = target_is_entrance ? pz : oz;
				float aa = target_is_entrance ? target_angle : partner_angle;
				float ba = target_is_entrance ? partner_angle : target_angle;
				snprintf(buf, sizeof(buf),
				         "%g %g %g %s %g %g %g %g %g  %g %g %g %s %g %g %g %g %g",
				         ax, ay, az, s, size, mr, mg, mb, aa,
				         bx, by, bz, s, size, mr, mg, mb, ba);
			} else {
				snprintf(buf, sizeof(buf),
				         "%g %g %g %s %g %g %g %g %g",
				         ox, oy, oz, s, size, mr, mg, mb, target_angle);
			}
		} else {
			snprintf(buf, sizeof(buf),
			         "%g %g %g %s %g %g %g %g %g",
			         ox, oy, oz, s, size, mr, mg, mb, target_angle);
		}
		Cvar_Set(Cvar_FindVar("minimap_highlight"), buf);
		// Does NOT auto-enable the minimap. Callers that want the
		// marker visible must set minimap_mode themselves first (parity
		// with setMinimapHighlight / setMinimapHeatmap).
	});

	// Seek the active demo to `seconds` from the start. Floors and clamps
	// to >= 0; no-ops when no demo is loaded, when the elapsed time isn't
	// known yet, or when the requested second is within 1s of current
	function("demoJump", +[](double seconds) {
		if (!cls.lastdemoname[0]) return;
		int elapsed_ms = Hub_GetDemoElapsedMs();
		if (elapsed_ms <= 0) return;
		int new_secs = (int) floor(seconds);
		if (new_secs < 0) new_secs = 0;
		float current_secs = elapsed_ms / 1000.0f;
		if (fabsf((float) new_secs - current_secs) < 1.0f) return;
		// Hub_GetDemoElapsedMs reports demo-relative ms; the engine's
		// `demo_jump` command takes the same unit as demtime, which is
		// absolute level time for NQ. Shift the demo-relative request
		// back into that frame so NQ seeks land in the right place.
		// QW/MVD have start_offset = 0, so this is a no-op there.
		extern int hub_demo_start_offset_ms;
		int abs_secs = new_secs + (hub_demo_start_offset_ms + 500) / 1000;
		char cmd[64];
		snprintf(cmd, sizeof(cmd), "demo_jump %d\n", abs_secs);
		Cbuf_AddText(cmd, RESTRICT_LOCAL);
	});

	// One-line summary of the current match. Built from the same
	// participant data as getParticipants. Output uses the original
	// UTF-8 names/teams (quake special chars and ^X color codes
	// preserved).
	//   local listen server      -> "Localhost"
	//   serverinfo mode == tot   -> "tot: <name1>, <name2>, ..."
	//   serverinfo mode contains "race"
	//                           -> "<name1>, <name2>, ..."
	//   teams.size() >= 2        -> "<team1> vs <team2>"
	//   players.size() == 2      -> "<name1> vs <name2>"
	//   serverinfo mode == 1on1
	//     and players.size() == 1 -> "<name1>"
	//   otherwise                -> "<N> players"
	// Returns "" when disconnected or no active players.
	function("getTitle", +[]() -> std::string {
		if (cls.state == ca_disconnected) return std::string();
#ifndef CLIENTONLY
		if (sv.state != ss_dead) return std::string("Localhost");
#endif

		hub_participants_t parts;
		Hub_BuildParticipants(&parts);

		auto join_player_names = [&](const char *prefix) -> std::string {
			std::string out = prefix;
			for (int i = 0; i < parts.player_count; i++) {
				if (i > 0) out += ", ";
				out += parts.players[i].name_unicode;
			}
			return out;
		};

		// NQ has no QW-style serverinfo - "mode" is always empty, so we
		// can't disambiguate tot / race / 1on1 from a tag. Fall through
		// directly to the team/player-count heuristics, same fallbacks
		// the QW path uses for unknown modes.
		if (cls.protocol == client_static_t::CP_NETQUAKE) {
			if (parts.team_count >= 2) {
				return std::string(parts.teams[0].team_unicode) + " vs " + std::string(parts.teams[1].team_unicode);
			}
			if (parts.player_count == 2) {
				return std::string(parts.players[0].name_unicode) + " vs " + std::string(parts.players[1].name_unicode);
			}
			if (parts.player_count == 1) {
				return std::string(parts.players[0].name_unicode);
			}
			if (parts.player_count == 0) return std::string();
			char buf[32];
			snprintf(buf, sizeof(buf), "%d players", parts.player_count);
			return std::string(buf);
		}

		const char *mode = InfoBuf_ValueForKey(&cl.serverinfo, "mode");

		if (!strcasecmp(mode, "tot")) {
			if (parts.player_count == 0) return std::string();
			return join_player_names("tot: ");
		}

		// Race modes have no head-to-head matchup - just list all players.
		if (mode && strstr(mode, "race")) {
			if (parts.player_count == 0) return std::string();
			return join_player_names("");
		}
		if (parts.team_count >= 2) {
			return std::string(parts.teams[0].team_unicode) + " vs " + std::string(parts.teams[1].team_unicode);
		}
		if (parts.player_count == 2) {
			return std::string(parts.players[0].name_unicode) + " vs " + std::string(parts.players[1].name_unicode);
		}
		if (!strcasecmp(mode, "1on1") && parts.player_count == 1) {
			return std::string(parts.players[0].name_unicode);
		}
		if (parts.player_count == 0) return std::string();

		char buf[32];
		snprintf(buf, sizeof(buf), "%d players", parts.player_count);
		return std::string(buf);
	});

}
