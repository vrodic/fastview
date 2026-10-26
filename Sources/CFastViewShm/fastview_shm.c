#include "fastview_shm.h"

#include <fcntl.h>
#include <sys/mman.h>

int fastview_shm_open(const char *name, int oflag, mode_t mode) {
    return shm_open(name, oflag, mode);
}

void *fastview_map_shared(int fd, size_t length) {
    void *base = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    return base == MAP_FAILED ? NULL : base;
}

void fastview_store_word(void *base, int index, uint64_t value) {
    __atomic_store_n((uint64_t *)base + index, value, __ATOMIC_RELEASE);
}

uint64_t fastview_load_word(const void *base, int index) {
    return __atomic_load_n((const uint64_t *)base + index, __ATOMIC_ACQUIRE);
}
