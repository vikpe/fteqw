// SPDX-License-Identifier: 0BSD

// Small math / easing helpers shared by the UI render passes (powcam slide,
// transitions, etc).

float(float x) EaseInExpo =
{
    if (x == 0.0) {
        return 0.0;
    }
    return pow(2.0, 10.0 * x - 10.0);
};
