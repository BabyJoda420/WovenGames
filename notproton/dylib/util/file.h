// File/Path Helpers.
#ifndef NOTPROTON_UTIL_FILE_H
#define NOTPROTON_UTIL_FILE_H

#include <stdint.h>
#include <stddef.h>

// Caller owns the returned buffer. Refuses anything over 16 MB.
uint8_t *np_read_whole_file(const char *path, size_t *out_len);

const char *np_home_dir(void);

// WOVEN_<name>, or the older NOTPROTON_<name> when that is unset.
const char *np_env(const char *name);

void np_support_path(char *buf, size_t bufsz, const char *home, const char *rel);

#endif // NOTPROTON_UTIL_FILE_H
