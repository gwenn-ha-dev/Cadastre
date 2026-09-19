#include "include/CadastreC.h"

#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/resource.h>
#include <sys/stat.h>

const uint32_t CAD_VREG = VREG;
const uint32_t CAD_VDIR = VDIR;
const uint32_t CAD_VLNK = VLNK;

void cad_set_io_policies(void) {
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                   IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
    setiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE,
                   IOPOL_SCOPE_PROCESS, IOPOL_VFS_TRIGGER_RESOLVE_OFF);
}

void cad_set_low_io_priority(void) {
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_UTILITY);
}

// The attribute set, in the order the kernel packs it: within each group,
// fields appear in ascending bit order, and the groups follow the order of
// struct attrlist. ATTR_CMN_RETURNED_ATTRS is special-cased first.
//
// Keep the request list and the decode loop in the same order.
static void cad_fill_attrlist(struct attrlist *al) {
    memset(al, 0, sizeof(*al));
    al->bitmapcount = ATTR_BIT_MAP_COUNT;
    al->commonattr  = ATTR_CMN_RETURNED_ATTRS
                    | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS
                    | ATTR_CMN_FILEID | ATTR_CMN_ERROR;
    al->dirattr     = ATTR_DIR_ENTRYCOUNT | ATTR_DIR_MOUNTSTATUS
                    | ATTR_DIR_ALLOCSIZE | ATTR_DIR_DATALENGTH;
    al->fileattr    = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
    // CMNEXT attributes ride in forkattr and need FSOPT_ATTR_CMN_EXTENDED.
    al->forkattr    = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_REALDEVID
                    | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT;
}

int cad_real_device(const char *path, uint32_t *out) {
    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS;
    al.forkattr = ATTR_CMNEXT_REALDEVID;

    struct { uint32_t len; attribute_set_t returned; uint32_t dev; } reply;
    if (getattrlist(path, &al, &reply, sizeof(reply), FSOPT_ATTR_CMN_EXTENDED) != 0) return -1;
    if (!(reply.returned.forkattr & ATTR_CMNEXT_REALDEVID)) { errno = ENOTSUP; return -1; }
    *out = reply.dev;
    return 0;
}

// Smallest possible on-the-wire entry: length + returned set + a name
// reference + a one-byte name. Used to clamp the reply buffer so the kernel
// can never hand back more entries than the caller has room to decode.
#define CAD_MIN_ENTRY 32

#define TAKE(dst, n) do { memcpy((dst), cursor, (n)); cursor += (n); } while (0)

int cad_bulk(int fd, void *scratch, size_t scratch_len, cad_entry *out, int out_cap) {
    if (out_cap <= 0) { errno = EINVAL; return -1; }

    size_t cap_bound = (size_t)out_cap * CAD_MIN_ENTRY;
    if (scratch_len > cap_bound) scratch_len = cap_bound;

    struct attrlist al;
    cad_fill_attrlist(&al);

    int n = getattrlistbulk(fd, &al, scratch, scratch_len,
                            FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW);
    if (n <= 0) return n;            // 0 = done, -1 = errno
    if (n > out_cap) { errno = ENOBUFS; return -2; }

    char *record = (char *)scratch;
    for (int i = 0; i < n; i++) {
        uint32_t record_len;
        memcpy(&record_len, record, sizeof(record_len));

        char *cursor = record + sizeof(uint32_t);
        attribute_set_t got;
        TAKE(&got, sizeof(got));

        cad_entry *e = &out[i];
        memset(e, 0, sizeof(*e));

        if (got.commonattr & ATTR_CMN_NAME) {
            attrreference_t ref;
            memcpy(&ref, cursor, sizeof(ref));
            const char *src = cursor + ref.attr_dataoffset;
            uint32_t len = ref.attr_length ? ref.attr_length - 1 : 0;  // drop NUL
            if (len >= CAD_NAME_CAP) { len = CAD_NAME_CAP - 1; e->valid |= CAD_V_TRUNC; }
            memcpy(e->name, src, len);
            e->name[len] = '\0';
            e->name_len = len;
            cursor += sizeof(ref);
        }
        if (got.commonattr & ATTR_CMN_OBJTYPE) TAKE(&e->objtype, 4);
        if (got.commonattr & ATTR_CMN_FLAGS)   TAKE(&e->flags, 4);
        if (got.commonattr & ATTR_CMN_FILEID)  TAKE(&e->fileid, 8);
        if (got.commonattr & ATTR_CMN_ERROR)   TAKE(&e->err, 4);

        if (got.dirattr & ATTR_DIR_ENTRYCOUNT)  TAKE(&e->entrycount, 4);
        if (got.dirattr & ATTR_DIR_MOUNTSTATUS) TAKE(&e->mountstatus, 4);
        if (got.dirattr & ATTR_DIR_ALLOCSIZE) { TAKE(&e->allocated, 8); e->valid |= CAD_V_ALLOC; }
        if (got.dirattr & ATTR_DIR_DATALENGTH)  TAKE(&e->logical, 8);

        if (got.fileattr & ATTR_FILE_LINKCOUNT) TAKE(&e->nlink, 4);
        if (got.fileattr & ATTR_FILE_TOTALSIZE) TAKE(&e->logical, 8);
        if (got.fileattr & ATTR_FILE_ALLOCSIZE) { TAKE(&e->allocated, 8); e->valid |= CAD_V_ALLOC; }

        if (got.forkattr & ATTR_CMNEXT_PRIVATESIZE)  { TAKE(&e->private_size, 8); e->valid |= CAD_V_PRIVATE; }
        if (got.forkattr & ATTR_CMNEXT_REALDEVID)    { TAKE(&e->dev, 4);          e->valid |= CAD_V_DEV; }
        if (got.forkattr & ATTR_CMNEXT_CLONEID)      { TAKE(&e->cloneid, 8);      e->valid |= CAD_V_CLONEID; }
        if (got.forkattr & ATTR_CMNEXT_CLONE_REFCNT) { TAKE(&e->clone_refcnt, 4); e->valid |= CAD_V_REFCNT; }

        record += record_len;
    }
    return n;
}
