// SPDX-License-Identifier: 0BSD

/*
 * Console command dispatcher.
 * Two top-level commands, both routed here from CSQC_ConsoleCommand:
 *   powcam   - powcam diagnostics (handlers in powcam_commands.qc)
 *   minimap  - minimap diagnostics (handlers in minimap_commands.qc)
 */

float(string cmd) CSQC_ConsoleCommand =
{
    tokenize_console(cmd);
    if (argv(0) == "minimap") {
        switch (argv(1)) {
        case "reload":  return MinimapCmdReload();
        case "status":  return MinimapCmdStatus();
        case "probe":   return MinimapCmdProbe();
        default:        return MinimapCmdHelp();
        }
    }
    if (argv(0) == "powcam") {
        switch (argv(1)) {
        case "active":  return PowcamCmdActive();
        case "timers":  return PowcamCmdTimers();
        case "recheck": return PowcamCmdRecheck();
        default:        return PowcamCmdHelp();
        }
    }
    if (argv(0) == "minimap_editor_add")    return CullEditAddCmd();
    if (argv(0) == "minimap_editor_remove") return CullEditRemoveCmd();
    if (argv(0) == "minimap_editor_undo")   return CullEditUndoCmd();
    if (argv(0) == "minimap_editor_export")   return CullEditExportCmd();
    return 0;
};
