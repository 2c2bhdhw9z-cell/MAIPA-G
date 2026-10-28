#include "CZlib.h"

int czlib_inflate_init2(z_streamp stream, int window_bits) {
    return inflateInit2(stream, window_bits);
}
