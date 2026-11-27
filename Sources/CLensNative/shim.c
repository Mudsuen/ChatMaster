#include "CLensNative.h"
#include "/opt/homebrew/opt/zstd/include/zstd.h"
#include <stdlib.h>

int lens_bind_text(sqlite3_stmt *stmt, int index, const char *text) {
    return sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT);
}

int lens_bind_blob(sqlite3_stmt *stmt, int index, const void *data, int length) {
    return sqlite3_bind_blob(stmt, index, data, length, SQLITE_TRANSIENT);
}

void *lens_zstd_decompress(const void *src, size_t src_len, size_t *out_len) {
    if (!src || src_len == 0 || !out_len) return NULL;
    ZSTD_DStream *ds = ZSTD_createDStream();
    if (!ds) return NULL;
    ZSTD_initDStream(ds);
    size_t cap = src_len * 4 + 1024;
    size_t len = 0;
    char *out = malloc(cap);
    if (!out) { ZSTD_freeDStream(ds); return NULL; }
    ZSTD_inBuffer in = { src, src_len, 0 };
    for (;;) {
        if (cap - len < 4096) {
            size_t ncap = cap * 2;
            if (ncap > (size_t)64 * 1024 * 1024) { free(out); ZSTD_freeDStream(ds); return NULL; }
            char *n = realloc(out, ncap);
            if (!n) { free(out); ZSTD_freeDStream(ds); return NULL; }
            out = n;
            cap = ncap;
        }
        ZSTD_outBuffer ob = { out + len, cap - len, 0 };
        size_t r = ZSTD_decompressStream(ds, &ob, &in);
        if (ZSTD_isError(r)) { free(out); ZSTD_freeDStream(ds); return NULL; }
        len += ob.pos;
        if (r == 0 && in.pos == in.size) break;           // last frame complete
        if (in.pos == in.size && ob.pos < ob.size) break; // input exhausted, nothing pending
    }
    ZSTD_freeDStream(ds);
    *out_len = len;
    return out;
}

void lens_free(void *ptr) { free(ptr); }
