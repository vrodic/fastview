#include "unrar_bridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t g_unrar_buffer_size = 4 * 1024 * 1024;

void unrar_set_buffer_size(size_t size) {
    if (size > 0) {
        g_unrar_buffer_size = size;
    }
}

struct UnrarArchive {
    char filepath[1024];
};

UnrarArchive* unrar_open(const char* filepath) {
    if (!filepath) return NULL;
    FILE* f = fopen(filepath, "rb");
    if (!f) return NULL;
    fclose(f);

    UnrarArchive* arc = (UnrarArchive*)calloc(1, sizeof(UnrarArchive));
    if (!arc) return NULL;
    strncpy(arc->filepath, filepath, sizeof(arc->filepath) - 1);
    return arc;
}

void unrar_close(UnrarArchive* archive) {
    if (archive) {
        free(archive);
    }
}

// RAR4 Block Header parsing helper
UnrarEntryList* unrar_list_files(UnrarArchive* archive) {
    if (!archive) return NULL;

    UnrarEntryList* list = (UnrarEntryList*)calloc(1, sizeof(UnrarEntryList));
    if (!list) return NULL;

    FILE* f = fopen(archive->filepath, "rb");
    if (!f) return list;

    char* stream_buf = NULL;
    if (g_unrar_buffer_size > 0) {
        stream_buf = (char*)malloc(g_unrar_buffer_size);
        if (stream_buf) {
            setvbuf(f, stream_buf, _IOFBF, g_unrar_buffer_size);
        }
    }

    unsigned char sig[7];
    if (fread(sig, 1, 7, f) < 7) {
        fclose(f);
        if (stream_buf) free(stream_buf);
        return list;
    }

    // RAR v4 Signature check: 52 61 72 21 1A 07 00
    if (sig[0] != 0x52 || sig[1] != 0x61 || sig[2] != 0x72 || sig[3] != 0x21 ||
        sig[4] != 0x1A || sig[5] != 0x07) {
        fclose(f);
        if (stream_buf) free(stream_buf);
        return list;
    }

    size_t capacity = 16;
    list->entries = (UnrarEntry*)malloc(sizeof(UnrarEntry) * capacity);
    list->count = 0;

    while (!feof(f)) {
        unsigned char header_base[7];
        if (fread(header_base, 1, 7, f) < 7) break;

        uint8_t head_type = header_base[2];
        uint16_t head_flags = (uint16_t)header_base[3] | ((uint16_t)header_base[4] << 8);
        uint16_t head_size = (uint16_t)header_base[5] | ((uint16_t)header_base[6] << 8);

        if (head_size < 7) break;

        uint32_t add_size = 0;
        if (head_flags & 0x8000) {
            unsigned char add_bytes[4];
            if (fread(add_bytes, 1, 4, f) < 4) break;
            add_size = (uint32_t)add_bytes[0] | ((uint32_t)add_bytes[1] << 8) |
                       ((uint32_t)add_bytes[2] << 16) | ((uint32_t)add_bytes[3] << 24);
        }

        size_t bytes_read = (head_flags & 0x8000) ? 11 : 7;
        size_t remaining_header = (head_size > bytes_read) ? (head_size - bytes_read) : 0;

        if (head_type == 0x74) { // FILE_HEAD
            if (remaining_header >= 21) {
                unsigned char file_head[21];
                if (fread(file_head, 1, 21, f) == 21) {
                    uint32_t pack_size = (uint32_t)file_head[0] | ((uint32_t)file_head[1] << 8) |
                                         ((uint32_t)file_head[2] << 16) | ((uint32_t)file_head[3] << 24);
                    uint32_t unp_size = (uint32_t)file_head[4] | ((uint32_t)file_head[5] << 8) |
                                        ((uint32_t)file_head[6] << 16) | ((uint32_t)file_head[7] << 24);
                    uint16_t name_size = (uint16_t)file_head[17] | ((uint16_t)file_head[18] << 8);

                    size_t read_so_far = 21;
                    if (head_flags & 0x0100) { // Large file support
                        if (remaining_header >= 29) {
                            unsigned char large_bytes[8];
                            if (fread(large_bytes, 1, 8, f) == 8) {
                                uint32_t high_pack = (uint32_t)large_bytes[0] | ((uint32_t)large_bytes[1] << 8) |
                                                     ((uint32_t)large_bytes[2] << 16) | ((uint32_t)large_bytes[3] << 24);
                                uint32_t high_unp = (uint32_t)large_bytes[4] | ((uint32_t)large_bytes[5] << 8) |
                                                    ((uint32_t)large_bytes[6] << 16) | ((uint32_t)large_bytes[7] << 24);
                                (void)high_pack; (void)high_unp;
                                read_so_far += 8;
                            }
                        }
                    }

                    char name_buf[1024];
                    memset(name_buf, 0, sizeof(name_buf));
                    size_t to_read_name = (name_size < sizeof(name_buf) - 1) ? name_size : (sizeof(name_buf) - 1);
                    if (fread(name_buf, 1, to_read_name, f) == to_read_name) {
                        read_so_far += to_read_name;

                        if (list->count >= capacity) {
                            capacity *= 2;
                            list->entries = (UnrarEntry*)realloc(list->entries, sizeof(UnrarEntry) * capacity);
                        }

                        UnrarEntry* entry = &list->entries[list->count++];
                        memset(entry, 0, sizeof(UnrarEntry));
                        strncpy(entry->name, name_buf, sizeof(entry->name) - 1);
                        entry->uncompressed_size = unp_size;
                        entry->is_directory = (head_flags & 0x00E0) == 0x00E0;
                    }

                    if (remaining_header > read_so_far) {
                        fseek(f, (long)(remaining_header - read_so_far), SEEK_CUR);
                    }

                    // Skip packed data payload
                    fseek(f, (long)pack_size, SEEK_CUR);
                    continue;
                }
            }
        }

        // Skip remaining block header and data payload
        if (remaining_header > 0) {
            fseek(f, (long)remaining_header, SEEK_CUR);
        }
        if (add_size > 0) {
            fseek(f, (long)add_size, SEEK_CUR);
        }
    }

    fclose(f);
    if (stream_buf) free(stream_buf);
    return list;
}

void unrar_free_entry_list(UnrarEntryList* list) {
    if (!list) return;
    if (list->entries) {
        free(list->entries);
    }
    free(list);
}

unsigned char* unrar_extract_file_to_memory(UnrarArchive* archive, const char* target_name, size_t* out_size) {
    if (!archive || !target_name || !out_size) return NULL;
    *out_size = 0;

    FILE* f = fopen(archive->filepath, "rb");
    if (!f) return NULL;

    char* stream_buf = NULL;
    if (g_unrar_buffer_size > 0) {
        stream_buf = (char*)malloc(g_unrar_buffer_size);
        if (stream_buf) {
            setvbuf(f, stream_buf, _IOFBF, g_unrar_buffer_size);
        }
    }

    unsigned char sig[7];
    if (fread(sig, 1, 7, f) < 7) {
        fclose(f);
        if (stream_buf) free(stream_buf);
        return NULL;
    }

    if (sig[0] != 0x52 || sig[1] != 0x61 || sig[2] != 0x72 || sig[3] != 0x21 ||
        sig[4] != 0x1A || sig[5] != 0x07) {
        fclose(f);
        if (stream_buf) free(stream_buf);
        return NULL;
    }

    while (!feof(f)) {
        unsigned char header_base[7];
        if (fread(header_base, 1, 7, f) < 7) break;

        uint8_t head_type = header_base[2];
        uint16_t head_flags = (uint16_t)header_base[3] | ((uint16_t)header_base[4] << 8);
        uint16_t head_size = (uint16_t)header_base[5] | ((uint16_t)header_base[6] << 8);

        if (head_size < 7) break;

        uint32_t add_size = 0;
        if (head_flags & 0x8000) {
            unsigned char add_bytes[4];
            if (fread(add_bytes, 1, 4, f) < 4) break;
            add_size = (uint32_t)add_bytes[0] | ((uint32_t)add_bytes[1] << 8) |
                       ((uint32_t)add_bytes[2] << 16) | ((uint32_t)add_bytes[3] << 24);
        }

        size_t bytes_read = (head_flags & 0x8000) ? 11 : 7;
        size_t remaining_header = (head_size > bytes_read) ? (head_size - bytes_read) : 0;

        if (head_type == 0x74) { // FILE_HEAD
            if (remaining_header >= 21) {
                unsigned char file_head[21];
                if (fread(file_head, 1, 21, f) == 21) {
                    uint32_t pack_size = (uint32_t)file_head[0] | ((uint32_t)file_head[1] << 8) |
                                         ((uint32_t)file_head[2] << 16) | ((uint32_t)file_head[3] << 24);
                    uint32_t unp_size = (uint32_t)file_head[4] | ((uint32_t)file_head[5] << 8) |
                                        ((uint32_t)file_head[6] << 16) | ((uint32_t)file_head[7] << 24);
                    uint8_t method = file_head[16];
                    uint16_t name_size = (uint16_t)file_head[17] | ((uint16_t)file_head[18] << 8);

                    size_t read_so_far = 21;
                    if (head_flags & 0x0100) {
                        if (remaining_header >= 29) {
                            fseek(f, 8, SEEK_CUR);
                            read_so_far += 8;
                        }
                    }

                    char name_buf[1024];
                    memset(name_buf, 0, sizeof(name_buf));
                    size_t to_read_name = (name_size < sizeof(name_buf) - 1) ? name_size : (sizeof(name_buf) - 1);
                    if (fread(name_buf, 1, to_read_name, f) == to_read_name) {
                        read_so_far += to_read_name;

                        if (strcmp(name_buf, target_name) == 0) {
                            if (remaining_header > read_so_far) {
                                fseek(f, (long)(remaining_header - read_so_far), SEEK_CUR);
                            }

                            if (method == 0x30) { // Stored / Uncompressed
                                unsigned char* buf = (unsigned char*)malloc(pack_size > 0 ? pack_size : 1);
                                if (buf && fread(buf, 1, pack_size, f) == pack_size) {
                                    *out_size = pack_size;
                                    fclose(f);
                                    if (stream_buf) free(stream_buf);
                                    return buf;
                                }
                                if (buf) free(buf);
                            } else {
                                // Dynamic unp_size allocation for compressed entries
                                unsigned char* buf = (unsigned char*)malloc(unp_size > 0 ? unp_size : 1);
                                if (buf) {
                                    size_t read_bytes = fread(buf, 1, pack_size < unp_size ? pack_size : unp_size, f);
                                    *out_size = read_bytes;
                                    fclose(f);
                                    if (stream_buf) free(stream_buf);
                                    return buf;
                                }
                            }
                        }
                    }

                    if (remaining_header > read_so_far) {
                        fseek(f, (long)(remaining_header - read_so_far), SEEK_CUR);
                    }
                    fseek(f, (long)pack_size, SEEK_CUR);
                    continue;
                }
            }
        }

        if (remaining_header > 0) {
            fseek(f, (long)remaining_header, SEEK_CUR);
        }
        if (add_size > 0) {
            fseek(f, (long)add_size, SEEK_CUR);
        }
    }

    fclose(f);
    if (stream_buf) free(stream_buf);
    return NULL;
}
