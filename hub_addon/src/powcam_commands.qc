// SPDX-License-Identifier: 0BSD

/*
 * Powcam console command handlers.
 * Dispatched from commands.qc:CSQC_ConsoleCommand.
 */

// Forward declarations (top-down ordering).
string(itemtype_t type) PowcamItemTypeLabel;

float() PowcamCmdActive =
{
    println("Powcam schedule:");
    println("  index           %d",    powcam.index);
    println("  intro (s)       %1.1f", powcam.intro_seconds);
    println("  outro (s)       %1.1f", powcam.outro_seconds);
    println("  transition (s)  %1.1f", powcam.transition_seconds);
    println("  start           %4.2f", powcam.start);
    println("  start-trans     %4.2f", powcam.start_transition);
    println("  end-trans       %4.2f", powcam.end_transition);
    println("  end             %4.2f", powcam.end);
    println("  now             %4.2f", time);
    return 1;
};

float() PowcamCmdTimers =
{
    println("Powcam timers:");
    item_timer_t *timers = ItemTimerGetAll();
    for (int i = 0; i < MAX_POWERUPS; i++) {
        item_timer_t *timer = &timers[i];
        if (!timer->item) {
            continue;
        }
        vector origin = getentity(timer->entnum, GE_ORIGIN);
        string spawned = (origin == '0 0 0') ? "no" : "yes";
        string by = "";
        if (timer->took > 0) {
            string name = getplayerkeyvalue(timer->playernum - 1, INFOKEY_P_NAME);
            by = sprintf(" by=%s(#%i)", name, (int)timer->playernum);
        }
        println("  [%i] entnum=%i type=%s took=%.2f respawn=%.2f spawned=%s%s",
                i, (int)timer->entnum, PowcamItemTypeLabel(timer->item->type),
                timer->took, timer->respawn, spawned, by);
    }
    println("  now             %4.2f", time);
    return 1;
};

float() PowcamCmdRecheck =
{
    if (powcam.index == -1) {
        println("Powcam: no camera scheduled");
        return 1;
    }
    if (time < powcam.start) {
        println("Powcam: window has not started");
        return 1;
    }

    item_timer_t *timers = ItemTimerGetAll();
    item_timer_t *timer = &timers[powcam.index];
    if (PowcamFindItemByEntity(timer->entnum) != nil) {
        println("Powcam: item still present, schedule kept");
        return 1;
    }

    PowcamReset();
    PowcamSelectNext();
    println("Powcam: rescheduled");
    return 1;
};

float() PowcamCmdHelp =
{
    println("Powcam commands:");
    println("  active   - currently scheduled camera");
    println("  timers   - all tracked timers");
    println("  recheck  - reset camera and try to schedule next");
    return 1;
};

// Returns a colored label for an item type, used by PowcamCmdTimers.
string(itemtype_t type) PowcamItemTypeLabel =
{
    switch (type) {
    case IT_QUAD: return "&c55fquad&r";
    case IT_PENT: return "&cf55pent&r";
    default:      return "none";
    }
};
