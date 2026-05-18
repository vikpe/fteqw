// SPDX-License-Identifier: 0BSD

/*
 * Shared 2D draw primitives.
 *
 * HubDrawRoundedRect tessellates a single convex polygon via R_BeginPolygon /
 * R_PolygonVertex / R_EndPolygon. `corners` is a bitmask of which corners
 * to round: RR_TL | RR_TR | RR_BR | RR_BL. Corners not in the mask emit
 * a single square vertex.
 *
 * HubSeatScale returns the per-seat shrink factor that overlays should
 * multiply their design-pixel sizes by so they stay readable when the
 * player view is sub-screen (splitscreen, minimap split). Mirrors ezhud's
 * hud_seat_scale (plugins/ezhud/ezquakeisms.c:EZHud_Draw).
 */

#define RR_TL 1
#define RR_TR 2
#define RR_BR 4
#define RR_BL 8
#define RR_TOP    (RR_TL | RR_TR)
#define RR_BOTTOM (RR_BR | RR_BL)
#define RR_ALL    (RR_TL | RR_TR | RR_BR | RR_BL)

void(vector pos, vector size, float radius, float corners, vector color, float alpha) HubDrawRoundedRect =
{
    if (radius < 1 || corners == 0) {
        drawfill(pos, [size.x, size.y, 0], color, alpha);
        return;
    }
    if (radius > size.x * 0.5) radius = size.x * 0.5;
    if (radius > size.y * 0.5) radius = size.y * 0.5;

    float  segments_per_corner = 5;
    vector center;
    float  angle;

    R_BeginPolygon("minimap_fill_v3", 0, 1);

    // Walk perimeter clockwise: TL -> TR -> BR -> BL. Each rounded corner
    // emits N+1 arc points; each square corner emits a single vertex.
    // Angles are in screen space (y-down); arc ranges chosen so consecutive
    // corners connect smoothly without overlap.
    if (corners & RR_TL) {
        center = [pos.x + radius, pos.y + radius, 0];
        for (int i = 0; i <= segments_per_corner; i++) {
            angle = M_PI + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center.x + cos(angle) * radius, center.y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([pos.x, pos.y, 0], '0 0 0', color, alpha);
    }

    if (corners & RR_TR) {
        center = [pos.x + size.x - radius, pos.y + radius, 0];
        for (int i = 0; i <= segments_per_corner; i++) {
            angle = 3 * M_PI / 2 + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center.x + cos(angle) * radius, center.y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([pos.x + size.x, pos.y, 0], '0 0 0', color, alpha);
    }

    if (corners & RR_BR) {
        center = [pos.x + size.x - radius, pos.y + size.y - radius, 0];
        for (int i = 0; i <= segments_per_corner; i++) {
            angle = (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center.x + cos(angle) * radius, center.y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([pos.x + size.x, pos.y + size.y, 0], '0 0 0', color, alpha);
    }

    if (corners & RR_BL) {
        center = [pos.x + radius, pos.y + size.y - radius, 0];
        for (int i = 0; i <= segments_per_corner; i++) {
            angle = M_PI / 2 + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center.x + cos(angle) * radius, center.y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([pos.x, pos.y + size.y, 0], '0 0 0', color, alpha);
    }

    R_EndPolygon();
};

// Per-seat shrink factor for overlay sizing. Returns sqrt(ratio) where
// ratio = min(view_w / vid_w, view_h / vid_h), clamped to [0.25, 1.0].
// The sqrt softens the shrink so half-axis seats stay legible (linear
// 0.5 would render 4px text). Matches ezhud's hud_seat_scale convention
// so an ezhud element at hud_*_scale N and an overlay at <name>_scale N
// render at the same size in the same seat.
//
// Pass the per-seat view_size (e.g. the view_size argument that
// CSQC_UpdateView routes into the overlay). VF_SCREENVSIZE provides the
// virtual canvas size for the comparison so the factor stays correct
// when vid_conwidth / vid_conheight don't match the physical viewport.
float(vector view_size) HubSeatScale =
{
    vector vid_size = getviewprop(VF_SCREENVSIZE);
    if (vid_size.x <= 0 || vid_size.y <= 0) return 1;

    float x_ratio = view_size.x / vid_size.x;
    float y_ratio = view_size.y / vid_size.y;
    float ratio   = bound(0.25, min(x_ratio, y_ratio), 1);
    return sqrt(ratio);
};
