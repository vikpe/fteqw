/*
 * Console command handlers. Two namespaces, both dispatched from
 * CSQC_ConsoleCommand:
 *   pip      - powcam diagnostics (active / timers / recheck / help)
 *   minimap  - minimap diagnostics, implemented in minimap.qc
 */

float() PowcamCmdActive =
{
    print("");

    println("Powcam state\n\n");
    println("Camera settings:");
    println("- index:      %3d", (float)powcam_index);
    println("- intro:      %1.1f", powcam_intro);
    println("- outro:      %1.1f", powcam_outro);
    println("- transition: %1.1f", powcam_transition);
    println("Camera schedule:");
    println("- start: %4.2f", powcam_start);
    println("- intro: %4.2f", powcam_start_transition);
    println("- outro: %4.2f", powcam_end_transition);
    println("- end:   %4.2f", powcam_end);
    println("Current Time: %4.2f", time);
    return 1;
};

float() PowcamCmdTimers =
{
    println("Powcam timer state\n");
    itemtimer_t *timers = PowcamGetTimers();
    for (int i = 0; i < MAX_POWERUPS; i++) {
        itemtimer_t *timer = &timers[i];
        if (!timer->item) {
            continue;
        }
        println("  index: %d", i);
        println(" entnum: %d", timer->entnum);
        println("   took: %.2f", timer->took);
        println("respawn: %.2f", timer->respawn);

        vector origin = getentity(timer->entnum, GE_ORIGIN);
        println("spawned: %s", origin == '0 0 0' ? "no" : "yes");

        if (timer->took > 0) {
            string name = getplayerkeyvalue(timer->playernum - 1, INFOKEY_P_NAME);
            println("     by: %s (num: %f)", name, timer->playernum);
        }

        print("   type: ");
        item_t *item = timer.item;
        switch (item.type) {
        case IT_QUAD:
            print("&c55fquad&r");
            break;
        case IT_PENT:
            print("&cf55pent&r");
            break;
        default:
            print("none");
            break;
        }
        print("\n\n");
    }
    println("Current time: %f", time);
    return 1;
};

float() PowcamCmdRecheck =
{
    if (powcam_index == -1) {
        return 1;
    }

    if (time < powcam_start) {
        debug("camera start not yet reached");
        return 1;
    }

    itemtimer_t *timers = PowcamGetTimers();
    itemtimer_t *timer = &timers[powcam_index];
    if (PowcamFindItemByEntity(timer->entnum) != nil) {
        debug("recheck found item");
        return 1;
    }

    ResetCamera();
    SelectNextCamera();

    return 1;
};

float() PowcamCmdHelp =
{
    println("Powcam commands");
    println(" * active  - Currently scheduled camera");
    println(" * timers  - All tracked timers");
    println(" * recheck - Reset camera and try to schedule next");
    return 1;
};

float(string cmd) CSQC_ConsoleCommand =
{
    tokenize_console(cmd);
    if (argv(0) == "minimap") {
        switch (argv(1)) {
        case "reload":
            return MinimapCmdReload();
        case "status":
            return MinimapCmdStatus();
        default:
            return MinimapCmdHelp();
        }
    }
    if (argv(0) != "powcam") {
        return 0;
    }
    switch (argv(1)) {
    case "active":
        return PowcamCmdActive();
    case "timers":
        return PowcamCmdTimers();
    case "recheck":
        return PowcamCmdRecheck();
    default:
        return PowcamCmdHelp();
    }
};
