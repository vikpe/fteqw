// SPDX-License-Identifier: 0BSD

/*
 * Xray rendering: through-walls silhouettes of nearby players so the
 * spectator can track action behind geometry. Triggered via the
 * progs/player.mdl deltalisten and a second renderscene pass using
 * MASK_XRAY (set up in main.qc CSQC_UpdateView).
 */

var float  autocvar_xray              = 1;
var float  autocvar_xray_alpha        = 0.3;
var float  autocvar_xray_distance     = 512;
var vector autocvar_xray_color_team   = '0 1 0';
var vector autocvar_xray_color_enemy  = '1 0 0';

// Cached shader source strings (one per team/enemy color). Baked once in
// XrayInit using the active xray_color_* cvars and re-bound per player by
// shaderforname() when the deltalisten fires.
var string xray_team_shader  = "";
var string xray_enemy_shader = "";

// Forward declarations (top-down ordering).
float(float isnew) XrayNewPlayer;
void(entity ent)   XrayResetPlayer;

// One-shot init from CSQC_WorldLoaded: bake the xray colour shaders and
// register the player-model deltalisten.
void() XrayInit =
{
    if (!autocvar_xray) {
        return;
    }

    xray_team_shader = sprintf(R"({
      {
        map $whiteimage
        rgbgen const %v
      }
    })", autocvar_xray_color_team);

    xray_enemy_shader = sprintf(R"({
      {
        map $whiteimage
        rgbgen const %v
      }
    })", autocvar_xray_color_enemy);

    deltalisten("progs/player.mdl", XrayNewPlayer, 0);
};

// deltalisten callback fired per player entity. Decides whether to draw
// this player through walls (close enough + occluded) or reset state.
float(float isnew) XrayNewPlayer =
{
    if (self.entnum == player_localentnum || !autocvar_xray) {
        XrayResetPlayer(self);
        return isnew;
    }

    float player_index = self.entnum - 1;
    float health = getplayerstat(player_index, STAT_HEALTH, EV_FLOAT);
    if (health <= 0) {
        XrayResetPlayer(self);
        return isnew;
    }

    vector view_origin = getviewprop(VF_ORIGIN);
    float  cutoff_distance = autocvar_xray_distance;

    float distance_to_player = vlen(view_origin - self.origin);
    if (distance_to_player > cutoff_distance) {
        XrayResetPlayer(self);
        return isnew;
    }

    traceline(view_origin, self.origin, MOVE_NORMAL | MOVE_NOMONSTERS, self);
    if (trace_fraction == 1) {
        XrayResetPlayer(self);
        return isnew;
    }

    float distance_fade = 1 - EaseInExpo(distance_to_player / cutoff_distance);

    self.effects |= EF_NODEPTHTEST | EF_ADDITIVE;
    self.drawmask = (self.drawmask & ~MASK_ENGINE) | MASK_XRAY;
    self.alpha    = autocvar_xray_alpha * distance_fade;
    self.fatness  = 2;

    // Workaround for self.origin not being lerped, bug in FTE, remove once fixed.
    vector lerped_origin = getentity(self.entnum, GE_ORIGIN);
    setorigin(self, lerped_origin);

    string pov_team = getplayerkeyvalue(player_localentnum - 1, "team");
    string ent_team = getplayerkeyvalue(player_index, "team");

    if (pov_team != ent_team) {
        self.forceshader = shaderforname("xray-enemy", xray_enemy_shader);
    } else {
        self.forceshader = shaderforname("xray-team", xray_team_shader);
    }

    return isnew;
};

// Clears xray draw state on a player entity (called when xray shouldn't
// apply: local player, dead, too far, or unobstructed).
void(entity ent) XrayResetPlayer =
{
    if (ent.entnum == player_localentnum) {
        ent.drawmask = MASK_LOCAL;
    } else {
        ent.drawmask = 0;
    }
    ent.effects     = 0;
    ent.alpha       = 0;
    ent.fatness     = 0;
    ent.forceshader = 0;
};
