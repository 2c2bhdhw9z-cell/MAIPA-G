#ifndef MAIPAG_CZLIB_H
#define MAIPAG_CZLIB_H

#include <zlib.h>

/// inflateInit2 is a macro in zlib.h, so Swift cannot call it. This is the same call as a function.
/// Pass 15 + 32 as windowBits to accept both gzip and zlib headers, which is what GitHub's tarballs
/// need (they are gzip).
int czlib_inflate_init2(z_streamp stream, int window_bits);

#endif
