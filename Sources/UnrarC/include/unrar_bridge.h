#ifndef UNRAR_BRIDGE_H
#define UNRAR_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct UnrarArchive UnrarArchive;

typedef struct {
    char name[1024];
    uint64_t uncompressed_size;
    bool is_directory;
} UnrarEntry;

typedef struct {
    UnrarEntry* entries;
    size_t count;
} UnrarEntryList;

UnrarArchive* unrar_open(const char* filepath);
void unrar_close(UnrarArchive* archive);
void unrar_set_buffer_size(size_t size);

UnrarEntryList* unrar_list_files(UnrarArchive* archive);
void unrar_free_entry_list(UnrarEntryList* list);

// Extracts the entry matching target_name directly into memory without writing to disk.
// Returns buffer pointer on success, NULL on failure. *out_size will be set to total bytes.
// The caller must free the returned buffer using free().
unsigned char* unrar_extract_file_to_memory(UnrarArchive* archive, const char* target_name, size_t* out_size);

#ifdef __cplusplus
}
#endif

#endif // UNRAR_BRIDGE_H
