#include "CThresholdArchive.h"
#include "archive.h"
#include "archive_entry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* No cwd changes: other app tasks may be using relative paths. */
static int safe_path(const char *path) {
    if (!path || !*path || *path == '/' || strchr(path, '\\')) return 0;
    char *copy = strdup(path), *save = NULL;
    int ok = 1;
    for (char *p = strtok_r(copy, "/", &save); p; p = strtok_r(NULL, "/", &save)) {
        if (!strcmp(p, "..") || !strcmp(p, ".")) { ok = 0; break; }
        for (const unsigned char *c = (unsigned char *)p; *c; c++)
            if (*c < 32 || *c == 127) ok = 0;
    }
    free(copy);
    return ok;
}

static int safe_link(const char *member, const char *target) {
    if (!target || !*target || *target == '/' || strchr(target, '\\')) return 0;
    int depth = 0;
    for (const char *p = member; *p; p++) if (*p == '/') depth++;
    char *copy = strdup(target), *save = NULL;
    int ok = 1;
    for (char *p = strtok_r(copy, "/", &save); p; p = strtok_r(NULL, "/", &save)) {
        if (!strcmp(p, "..")) { if (--depth < 0) { ok = 0; break; } }
        else if (strcmp(p, ".")) depth++;
    }
    free(copy);
    return ok;
}

int threshold_extract(const char *archive_path, const char *destination, char *error, size_t error_size) {
    struct archive *a = archive_read_new(), *disk = archive_write_disk_new();
    struct archive_entry *entry;
    int result = -1, status;
    char *root = NULL;
    char *resolved = realpath(destination, NULL);
    unsigned long long total = 0;
    if (!resolved) goto unsafe;
    archive_read_support_filter_xz(a);
    archive_read_support_format_tar(a);
    archive_write_disk_set_options(disk, ARCHIVE_EXTRACT_SECURE_SYMLINKS |
        ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_NO_OVERWRITE | ARCHIVE_EXTRACT_PERM);
    if (archive_read_open_filename(a, archive_path, 65536) != ARCHIVE_OK) goto fail;
    while ((status = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname(entry);
        if (!safe_path(name) || archive_entry_hardlink(entry)) goto unsafe;
        size_t length = strcspn(name, "/");
        if (!root) root = strndup(name, length);
        if (strlen(root) != length || strncmp(root, name, length)) goto unsafe;
        const char *member = name + length;
        while (*member == '/') member++;
        mode_t type = archive_entry_filetype(entry);
        if (type != AE_IFDIR && type != AE_IFREG && type != AE_IFLNK) goto unsafe;
        if (!*member) { if (type != AE_IFDIR) goto unsafe; continue; }
        if (type == AE_IFLNK && !safe_link(member, archive_entry_symlink(entry))) goto unsafe;
        la_int64_t size = archive_entry_size(entry);
        if (size < 0 || (total += size) > 20ULL * 1024 * 1024 * 1024) goto unsafe;
        char *path = NULL;
        if (asprintf(&path, "%s/%s", resolved, member) < 0) goto unsafe;
        archive_entry_set_pathname(entry, path);
        free(path);
        archive_entry_set_perm(entry, type == AE_IFDIR ? 0755 :
            (archive_entry_perm(entry) & 0111 ? 0755 : 0644));
        if (archive_write_header(disk, entry) != ARCHIVE_OK) goto fail;
        const void *buffer;
        size_t count;
        la_int64_t offset;
        while ((status = archive_read_data_block(a, &buffer, &count, &offset)) == ARCHIVE_OK) {
            if (offset < 0 || (unsigned long long)offset + count > (unsigned long long)size) goto unsafe;
            if (archive_write_data_block(disk, buffer, count, offset) != ARCHIVE_OK) goto fail;
        }
        if (status != ARCHIVE_EOF || archive_write_finish_entry(disk) != ARCHIVE_OK) goto fail;
    }
    if (status != ARCHIVE_EOF || !root) goto unsafe;
    result = 0;
    goto done;
unsafe:
    snprintf(error, error_size, "Archive contains an unsafe path, link, entry type or size.");
    goto done;
fail:
    snprintf(error, error_size, "%s", archive_error_string(disk) ? archive_error_string(disk) :
        (archive_error_string(a) ? archive_error_string(a) : "Archive extraction failed."));
done:
    free(root);
    free(resolved);
    archive_read_free(a);
    archive_write_free(disk);
    return result;
}
