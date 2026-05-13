/*
 * Xray rendering: through-walls silhouettes of nearby players so the
 * spectator can track action behind geometry. Triggered via the
 * progs/player.mdl deltalisten and a second renderscene pass using
 * MASK_XRAY (set up in main.qc CSQC_UpdateView).
 */

var float autocvar_qdw_xray = 1;
var float autocvar_qdw_xray_alpha = 0.3;
var float autocvar_qdw_xray_distance = 512;
var vector autocvar_qdw_xray_color_team = '0 1 0';
var vector autocvar_qdw_xray_color_enemy = '1 0 0';

var string team_shader = "";
var string enemy_shader = "";

void(entity ent) XrayResetPlayer =
{
    if (ent.entnum == player_localentnum) {
        ent.drawmask = MASK_LOCAL;
    } else {
        ent.drawmask = 0;
    }
    ent.effects = 0;
    ent.alpha = 0;
    ent.fatness = 0;
    ent.forceshader = 0;
};

float(float isnew) XrayNewPlayer =
{
    if (self.entnum == player_localentnum || !autocvar_qdw_xray) {
        XrayResetPlayer(self);
        return isnew;
    }

    float pnum = self.entnum - 1;
    float health = getplayerstat(pnum, STAT_HEALTH, EV_FLOAT);
    if (health <= 0) {
        XrayResetPlayer(self);
        return isnew;
    }

    vector org = getviewprop(VF_ORIGIN);
    float cutoff = autocvar_qdw_xray_distance;

    float distance = vlen(org - self.origin);
    if (distance > cutoff) {
        XrayResetPlayer(self);
        return isnew;
    }

    traceline(org, self.origin, MOVE_NORMAL | MOVE_NOMONSTERS, self);
    if (trace_fraction == 1) {
        XrayResetPlayer(self);
        return isnew;
    }

    float distanceFactor = 1 - easeInExpo(distance / cutoff);

    self.effects |= EF_NODEPTHTEST | EF_ADDITIVE;
    self.drawmask = (self.drawmask & ~MASK_ENGINE) | MASK_XRAY;
    self.alpha = autocvar_qdw_xray_alpha * distanceFactor;
    self.fatness = 2;

    // Workaround for self.origin not being lerped, bug in FTE, remove once fixed.
    vector origin = getentity(self.entnum, GE_ORIGIN);
    setorigin(self, origin);

    string pov_team = getplayerkeyvalue(player_localentnum - 1, "team");
    string ent_team = getplayerkeyvalue(pnum, "team");

    if (pov_team != ent_team) {
        self.forceshader = shaderforname("xray-enemy", enemy_shader);
    } else {
        self.forceshader = shaderforname("xray-team", team_shader);
    }

    return isnew;
};

// One-shot init from CSQC_WorldLoaded: bake the xray colour shaders and
// register the player-model deltalisten.
void() XrayInit =
{
    if (!autocvar_qdw_xray) {
        return;
    }

    team_shader = sprintf(R"({
      {
        map $whiteimage
        rgbgen const %v
      }
    })", autocvar_qdw_xray_color_team);

    enemy_shader = sprintf(R"({
      {
        map $whiteimage
        rgbgen const %v
      }
    })", autocvar_qdw_xray_color_enemy);

    deltalisten("progs/player.mdl", XrayNewPlayer, 0);
};
