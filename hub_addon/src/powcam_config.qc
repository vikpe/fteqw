// SPDX-License-Identifier: 0BSD

// Increase if any predefined map needs more.. "(shrug)"
#define MAX_POWERUPS 4

typedef struct {
        vector origin;
        vector angles;
} powcam_camera_t;

typedef struct {
    itemtype_t type;
    vector origin;
    powcam_camera_t camera;
} powcam_item_t;

// Defines to make the database somewhat of an embedded DSL.
#define origin(x) x
#define angles(x) x
#define camera(org, ang) { org, ang }
#define powerup(typ, org, cam) { typ, org, cam }
#define quad(org, cam) powerup(IT_QUAD, org, cam)
#define pent(org, cam) powerup(IT_PENT, org, cam)
#define map(name, ...) { name, { __VA_ARGS__ } }

// Per-map powerup -> camera lookup table. Each entry is keyed on map name
// and contains up to MAX_POWERUPS powerup origins paired with the camera
// pose to use when that powerup is the scheduled focus.
struct {
    string name;
    powcam_item_t items[MAX_POWERUPS];
} powcam_map_database[] = {
    map("dm2",
        quad('1920 -704 184', camera(origin('1846 -585 355'), angles('71 0 0')))
    ),
    map("dm3",
        quad('952 296 56', camera(origin('986 316 91'), angles('27 225 0'))),
        pent('1008 800 -296', camera(origin('1239 664 113'), angles('51 139 0')))
    ),
    map("e1m2",
        quad('400 -1360 432', camera(origin('332 -1243 515'), angles('41 11 0')))
    ),
    map("e2m2",
        quad('-184 1512 144', camera(origin('-266 1582 172'), angles('23 322 0')))
    ),
    map("e2m5",
        quad('8 -416 -16', camera(origin('169 -210 100'), angles('27 227 0'))),
        quad('-32 2432 88', camera(origin('54 2432 191'), angles('22 180 0'))),
        pent('-320 1088 -423', camera(origin('-154 1005 -306'), angles('41 135 0')))
    ),
    map("e3m6",
        quad('32 -8 56', camera(origin('22 -131 93'), angles('33 40 0')))
    ),
    map("ctf5",
        quad('-672 1188 -496', camera(origin('-850 1188 -526'), angles('-22 360 0')))
    ),
    map("ctf8",
        quad('652 468 160', camera(origin('692 493 278'), angles('57 228 0')))
    ),
    map("ctf2m1",
        quad('160 -1584 -208', camera(origin('160 -1649 -33'), angles('69 90 0'))),
        pent('-296 -1584 -80', camera(origin('51 -1584 -118'), angles('-4 180 0')))
    ),
    map("ctf2m3",
        quad('803 -684 199', camera(origin('636 -684 271'), angles('28 360 0')))
    ),
    map("ztndm3",
        quad('-168 824 352', camera(origin('-200 856 411'), angles('45 253 0'))),
    ),
    map("schloss",
        quad('-216 -3344 456', camera(origin('-280 -3354 511'), angles('35 36 0'))),
        pent('352 -2152 264', camera(origin('453 -2170 361'), angles('42 228 0')))
    ),
    map("phantombase",
        quad('192 256 24', camera(origin('271 350 49'), angles('17 229 0'))),
        pent('-640 -256 24', camera(origin('-735 -333 58'), angles('23 39 0')))
    ),
    map("bravado",
        quad('752 24 288', camera(origin('820 -9 374'), angles('45 142 0')))
    ),
    map("shifter",
        quad('40 -24 168', camera(origin('81 -138 239'), angles('37 108 0')))
    ),
    map("catalyst",
        quad('836 14 235', camera(origin('748 -85 282'), angles('26 48 0')))
    ),
    map("ultrav",
        quad('608 -768 632', camera(origin('610 -772 716'), angles('90 1 0')))
    ),
};

#undef map
#undef pent
#undef quad
#undef powerup
#undef camera
#undef angles
#undef origin

// Pointer into powcam_map_database for the currently loaded map, or nil if
// the current map has no entry. Lookup happens once in PowcamLoadItems().
// (`mapname` is an engine-provided global declared by csplat.qc - the
// engine populates it on world load.)
var powcam_item_t* powcam_active_items = nil;

// Cached count of entries in powcam_active_items (lazy filled by
// PowcamCountItems on first call). Counts up to the first IT_NONE sentinel.
var int   powcam_active_item_count   = 0;
var float powcam_active_item_counted = 0;

// Forward declarations (top-down ordering).
powcam_item_t*(vector org, float model_index)                                  PowcamFindItem;
powcam_item_t*(vector origin, vector tolerance, itemtype_t expected_type)      PowcamFindItemInternal;
powcam_item_t*()                                                                PowcamGetCurrentItems;
int()                                                                           PowcamCountItems;

// Binds the active map's entry from powcam_map_database. Returns 1 if the
// current map has cameras defined.
//
// Powcam is a demo-only feature - the camera scheduler relies on knowing
// when items respawn, which is only meaningful when reviewing a recorded
// match. Outside demo playback, return 0 so main.qc skips deltalisten
// registration and no spawn listeners get attached.
float() PowcamLoadItems =
{
    if (!isdemo()) {
        return 0;
    }
    for (int i = 0; i < powcam_map_database.length; i++) {
        if (powcam_map_database[i].name == mapname) {
            powcam_active_items = powcam_map_database[i].items;
            return 1;
        }
    }
    return 0;
};

// Looks up an item by server entity number.
powcam_item_t*(float entnum) PowcamFindItemByEntity =
{
    vector org = getentity(entnum, GE_ORIGIN);
    float model_index = getentity(entnum, GE_MODELINDEX);
    return PowcamFindItem(org, model_index);
};

// Looks up an item by current origin + model. Returns nil if either is
// the zero sentinel.
powcam_item_t*(vector org, float model_index) PowcamFindItem =
{
    if (org == '0 0 0') {
        debug("zero origin, skipping");
        return nil;
    }
    if (model_index == 0) {
        debug("zero type, skipping");
        return nil;
    }
    itemtype_t type = ItemTypeByModelIndex(model_index);
    return PowcamFindItemInternal(org, '0 0 64', type);
};

// Inner lookup: scan powcam_active_items for an entry matching `origin`
// (within `tolerance`) and `expected_type`. Falls back to the only entry
// on single-item maps.
powcam_item_t*(vector origin, vector tolerance, itemtype_t expected_type) PowcamFindItemInternal =
{
    powcam_item_t *items = PowcamGetCurrentItems();
    if (!items)
        return nil;

    for (int i = 0; i < MAX_POWERUPS; i++) {
        powcam_item_t *item = &items[i];
        if (item->type == IT_NONE) {
            break;
        }
        if (item->type != expected_type) {
            continue;
        }
        if (fabs(item->origin.x - origin.x) <= tolerance.x &&
            fabs(item->origin.y - origin.y) <= tolerance.y &&
            fabs(item->origin.z - origin.z) <= tolerance.z) {
            return item;
        }
    }

    // Fallback if map only has a single camera.
    if (PowcamCountItems() == 1) {
        return &items[0];
    }

    debug("No camera matched origin %v (type %d) on map '%s'", origin, expected_type, mapname);
    return nil;
};

// Returns the active map's item array, or nil if the map has no entry.
powcam_item_t*() PowcamGetCurrentItems =
{
    if (!powcam_active_items)
        return nil;
    return powcam_active_items;
};

// Counts entries in powcam_active_items up to the first IT_NONE sentinel.
// Lazy-cached on first call.
int() PowcamCountItems =
{
    if (!powcam_active_item_counted) {
        powcam_item_t *items = PowcamGetCurrentItems();
        for (int i = 0; items && i < MAX_POWERUPS; i++) {
            if (items[i].type == IT_NONE)
                break;
            powcam_active_item_count += 1;
        }
        powcam_active_item_counted = 1;
    }
    return powcam_active_item_count;
};
