// SPDX-License-Identifier: 0BSD

/*
 * Shared 2D draw primitives.
 *
 * HubDrawRoundedRect tessellates a single convex polygon via R_BeginPolygon /
 * R_PolygonVertex / R_EndPolygon. `corners` is a bitmask of which corners
 * to round: RR_TL | RR_TR | RR_BR | RR_BL. Corners not in the mask emit
 * a single square vertex.
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
