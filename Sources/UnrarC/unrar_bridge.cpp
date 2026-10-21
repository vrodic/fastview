#include "include/unrar_bridge.h"
#include "dll.hpp"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>
#include <string>
#include <cwchar>
#include <climits>

static size_t g_unrar_buffer_size = 4 * 1024 * 1024;

extern "C" {

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

static std::string get_entry_name(const RARHeaderDataEx& headerData) {
    if (headerData.FileNameW[0] != 0) {
        std::string utf8Name;
        mbstate_t state = mbstate_t();
        for (int i = 0; headerData.FileNameW[i] != 0; ++i) {
            char buf[MB_LEN_MAX + 1];
            size_t len = wcrtomb(buf, headerData.FileNameW[i], &state);
            if (len != (size_t)-1 && len > 0) {
                buf[len] = '\0';
                utf8Name += buf;
            }
        }
        if (!utf8Name.empty()) {
            return utf8Name;
        }
    }
    return std::string(headerData.FileName);
}

UnrarEntryList* unrar_list_files(UnrarArchive* archive) {
    if (!archive) return NULL;

    RAROpenArchiveDataEx openData;
    memset(&openData, 0, sizeof(openData));
    openData.ArcName = archive->filepath;
    openData.OpenMode = RAR_OM_LIST;

    HANDLE hArc = RAROpenArchiveDataEx(&openData);
    if (!hArc || openData.OpenResult != 0) {
        return NULL;
    }

    UnrarEntryList* list = (UnrarEntryList*)calloc(1, sizeof(UnrarEntryList));
    if (!list) {
        RARCloseArchive(hArc);
        return NULL;
    }

    size_t capacity = 16;
    list->entries = (UnrarEntry*)malloc(sizeof(UnrarEntry) * capacity);
    list->count = 0;

    RARHeaderDataEx headerData;
    memset(&headerData, 0, sizeof(headerData));

    while (RARReadHeaderEx(hArc, &headerData) == ERAR_SUCCESS) {
        if (list->count >= capacity) {
            capacity *= 2;
            list->entries = (UnrarEntry*)realloc(list->entries, sizeof(UnrarEntry) * capacity);
        }

        UnrarEntry* entry = &list->entries[list->count++];
        memset(entry, 0, sizeof(UnrarEntry));

        std::string name = get_entry_name(headerData);
        strncpy(entry->name, name.c_str(), sizeof(entry->name) - 1);

        entry->uncompressed_size = ((uint64_t)headerData.UnpSizeHigh << 32) | headerData.UnpSize;
        entry->is_directory = (headerData.Flags & RHDF_DIRECTORY) != 0;

        RARProcessFile(hArc, RAR_SKIP, NULL, NULL);
    }

    RARCloseArchive(hArc);
    return list;
}

void unrar_free_entry_list(UnrarEntryList* list) {
    if (!list) return;
    if (list->entries) {
        free(list->entries);
    }
    free(list);
}

struct MemoryBufferContext {
    std::vector<unsigned char> data;
};

static int CALLBACK extract_callback(UINT msg, LPARAM userData, LPARAM p1, LPARAM p2) {
    if (msg == UCM_PROCESSDATA) {
        MemoryBufferContext* ctx = (MemoryBufferContext*)userData;
        if (ctx && p1 && p2 > 0) {
            unsigned char* chunk = (unsigned char*)p1;
            size_t chunkSize = (size_t)p2;
            ctx->data.insert(ctx->data.end(), chunk, chunk + chunkSize);
        }
    }
    return 1;
}

unsigned char* unrar_extract_file_to_memory(UnrarArchive* archive, const char* target_name, size_t* out_size) {
    if (!archive || !target_name || !out_size) return NULL;
    *out_size = 0;

    RAROpenArchiveDataEx openData;
    memset(&openData, 0, sizeof(openData));
    openData.ArcName = archive->filepath;
    openData.OpenMode = RAR_OM_EXTRACT;

    HANDLE hArc = RAROpenArchiveDataEx(&openData);
    if (!hArc || openData.OpenResult != 0) {
        return NULL;
    }

    MemoryBufferContext ctx;
    RARSetCallback(hArc, extract_callback, (LPARAM)&ctx);

    RARHeaderDataEx headerData;
    memset(&headerData, 0, sizeof(headerData));
    bool found = false;

    while (RARReadHeaderEx(hArc, &headerData) == ERAR_SUCCESS) {
        std::string entryName = get_entry_name(headerData);
        if (entryName == target_name) {
            int res = RARProcessFile(hArc, RAR_EXTRACT, NULL, NULL);
            if (res == ERAR_SUCCESS) {
                found = true;
            }
            break;
        } else {
            RARProcessFile(hArc, RAR_SKIP, NULL, NULL);
        }
    }

    RARCloseArchive(hArc);

    if (found && !ctx.data.empty()) {
        *out_size = ctx.data.size();
        unsigned char* buffer = (unsigned char*)malloc(ctx.data.size());
        if (buffer) {
            memcpy(buffer, ctx.data.data(), ctx.data.size());
            return buffer;
        }
    }
    return NULL;
}

} // extern "C"
