// SPDX-License-Identifier: 0BSD

typedef struct {
    float entnum;     // server entity number of the powerup item
    float took;       // engine `time` when last picked up (0 = never)
    float respawn;    // engine `time` of the next scheduled respawn
    float playernum;  // user index (1-based) of the player who took it
    powcam_item_t *item;     // pointer into powcam_active_items[] for this slot
} item_timer_t;

// Pickup timer state, one slot per tracked powerup on the current map.
// Populated by the CSQC_Parse_StuffCmd "//ktx took" handler and by the
// deltalisten spawn listener. Read by the powcam scheduler and the
// commands UI. timer->item points into powcam_active_items[].
item_timer_t item_timers[MAX_POWERUPS];

item_timer_t*() ItemTimerGetAll =
{
    return item_timers;
};

item_timer_t*(int index) ItemTimerGet =
{
    item_timer_t *timer = &item_timers[index];
    if (timer && !timer->item)
        return nil;
    return timer;
}

float(float isnew) ItemTimerSpawnListener =
{
    for (int i = 0; i < MAX_POWERUPS; i++) {
        item_timer_t *timer = &item_timers[i];
        if (timer->entnum != self.entnum && timer->entnum > 0) {
            continue;
        }

        timer->entnum = self.entnum;

        if (!timer->item) {
            timer->item = PowcamFindItem(self.origin, self.modelindex);
            if (timer->item) {
                debug("Associated timer via listener");
            }
        }

        break;
    }

    return isnew;
};

void(float timestamp) ItemTimerResetAll =
{
    for (int i = 0; i < MAX_POWERUPS; i++) {
        item_timer_t *timer = &item_timers[i];
        timer->respawn   = timestamp;
        timer->entnum    = 0;
        timer->playernum = 0;
        timer->took      = 0;
        timer->respawn   = 0;
        timer->item      = nil;
    }
}

void(string msg) CSQC_Parse_StuffCmd =
{
    if (!PowcamGetCurrentItems())
        return;

    if (strncmp(msg, "//ktx took ", 10)) {
        return;
    }

    // //ktx took <entnum>(0) <delay>(1) <playernum>(2)
    msg = substring(msg, 11, -1);

    tokenize_console(msg);

    float respawn_delay = stof(argv(1));

    itemtype_t type = ItemTypeByRespawnDelay(respawn_delay);

    // Lets assume standardized quad and pent respawn timers
    if (!(type == IT_QUAD || type == IT_PENT)) {
        return;
    }

    float entnum    = stof(argv(0));
    float playernum = stof(argv(2));

    for (int i = 0; i < MAX_POWERUPS; i++) {
        item_timer_t *timer = &item_timers[i];
        if (timer->entnum != 0 && entnum != timer->entnum) {
            continue;
        }

        if (!timer->item) {
            powcam_item_t *item = PowcamFindItemByEntity(entnum);
            if (!item) {
                debug("ITEM NOT FOUND!");
                return;
            }
            timer->item   = item;
            timer->entnum = entnum;
        }

        timer->respawn   = time + respawn_delay;
        timer->took      = time;
        timer->playernum = playernum;
        break;
    }
};
