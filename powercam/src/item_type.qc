// SPDX-License-Identifier: 0BSD

typedef enum {
    IT_NONE,
    IT_QUAD,
    IT_PENT,
} itemtype_t;

itemtype_t(float model_index) ItemTypeByModelIndex =
{
    if (!model_index) {
        return IT_NONE;
    }

    string model_name = modelnameforindex(model_index);
    switch (model_name) {
    case "progs/quaddama.mdl":
        return IT_QUAD;
    case "progs/invulner.mdl":
        return IT_PENT;
    default:
        return IT_NONE;
    }
};

itemtype_t(float respawn_delay) ItemTypeByRespawnDelay =
{
    switch (respawn_delay) {
    case 60:
        return IT_QUAD;
    case 300:
        return IT_PENT;
    default:
        return IT_NONE;
    }
};
