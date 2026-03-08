#include "calc.h"

static const char *version_string = "1.0.0";

calc_result calc_add(int a, int b) {
    calc_result r;
    r.a = a;
    r.b = b;
    r.sum = a + b;
    return r;
}

const char *calc_version(void) {
    return version_string;
}
