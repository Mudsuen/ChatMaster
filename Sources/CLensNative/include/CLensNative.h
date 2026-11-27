#ifndef CLENSNATIVE_H
#define CLENSNATIVE_H

#include <stddef.h>
// Absolute includes keep Swift clients free of extra header search flags.
#include "/opt/homebrew/opt/sqlcipher/include/sqlcipher/sqlite3.h"

/// sqlite3_bind_* with SQLITE_TRANSIENT (the macro does not import into Swift).
int lens_bind_text(sqlite3_stmt *stmt, int index, const char *text);
int lens_bind_blob(sqlite3_stmt *stmt, int index, const void *data, int length);

/// Decompress one or more zstd frames. Returns a malloc'd buffer (free with lens_free) or NULL.
void *lens_zstd_decompress(const void *src, size_t src_len, size_t *out_len);
void lens_free(void *ptr);

#endif
