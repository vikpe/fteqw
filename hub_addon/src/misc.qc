// SPDX-License-Identifier: 0BSD

/*
 * Miscellaneous mode-driven side effects.
 *
 * CTF skin handling: when serverinfo "mode" becomes "ctf" we clear
 * teamskin/enemyskin so per-player skins are honored. Original values
 * are restored when the mode changes back. State is in MiscCtf*.
 *
 * Driven by CSQC_ServerInfoChanged - Misc_OnServerInfoChanged is the
 * single entry point.
 */

string MiscCtfSavedTeamskin;
string MiscCtfSavedEnemyskin;
float  MiscCtfActive;            // 1 when CTF overrides are currently applied

void() Misc_OnServerInfoChanged;
void() Misc_ApplyCtfSkins;
void() Misc_RestoreSkins;

void() Misc_OnServerInfoChanged =
{
    string mode = serverkey("mode");
    if (!strcasecmp(mode, "ctf")) {
        Misc_ApplyCtfSkins();
    } else {
        Misc_RestoreSkins();
    }
};

void() Misc_ApplyCtfSkins =
{
    if (MiscCtfActive) return;

    MiscCtfSavedTeamskin  = cvar_string("teamskin");
    MiscCtfSavedEnemyskin = cvar_string("enemyskin");
    cvar_set("teamskin",  "");
    cvar_set("enemyskin", "");
    MiscCtfActive = 1;
};

void() Misc_RestoreSkins =
{
    if (!MiscCtfActive) return;

    cvar_set("teamskin",  MiscCtfSavedTeamskin);
    cvar_set("enemyskin", MiscCtfSavedEnemyskin);
    MiscCtfActive = 0;
};
