// Small math / easing helpers shared by the UI render passes (PiP slide,
// transitions, etc).

float(float x) easeInExpo =
{
    if (x == 0.0) {
        return 0.0;
    }
    return pow(2.0, 10.0 * x - 10.0);
};
