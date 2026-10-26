#ifndef FASTVIEW_SHM_H
#define FASTVIEW_SHM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/// Layout of a shared-memory region exchanged with the FastViewReader
/// helper: a header page of 64-bit control words, followed by the payload.
#define FASTVIEW_SHM_HEADER_SIZE 16384

/// shm_open(2) is variadic, which Swift cannot call directly.
int fastview_shm_open(const char *name, int oflag, mode_t mode);

/// mmap(2) of `length` bytes of `fd`, shared and read/write; NULL on failure.
void *fastview_map_shared(int fd, size_t length);

/// 64-bit control word `index` of the region header (release store /
/// acquire load).  Word 1 is the bytes-read counter of a whole-file read.
void fastview_store_word(void *base, int index, uint64_t value);
uint64_t fastview_load_word(const void *base, int index);

#endif
