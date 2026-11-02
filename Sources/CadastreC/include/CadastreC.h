// Low-level Darwin glue for the Cadastre scanner.
//
// Two jobs the Swift side should not have to do itself:
//   1. set the process I/O policies that make a disk scan safe on macOS
//   2. decode the packed getattrlistbulk(2) reply buffer
//
// The decoder exists in C because the reply is a stream of variable-length,
// unaligned records whose layout depends on a per-entry bitmask. Doing that
// with Swift's typed pointers is possible but reads far worse than the
// memcpy-and-advance loop below.

#ifndef CADASTRE_C_H
#define CADASTRE_C_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

// APFS allows 255 UTF-16 units per name: up to 765 bytes of UTF-8.
#define CAD_NAME_CAP 1024

// Which optional fields the filesystem actually returned for an entry.
#define CAD_V_PRIVATE  0x01u   // ATTR_CMNEXT_PRIVATESIZE
#define CAD_V_REFCNT   0x02u   // ATTR_CMNEXT_CLONE_REFCNT
#define CAD_V_ALLOC    0x04u   // ATTR_FILE_ALLOCSIZE / ATTR_DIR_ALLOCSIZE
#define CAD_V_CLONEID  0x08u   // ATTR_CMNEXT_CLONEID
#define CAD_V_DEV      0x10u   // ATTR_CMNEXT_REALDEVID
#define CAD_V_TRUNC    0x20u   // name longer than CAD_NAME_CAP, truncated

typedef struct {
    char     name[CAD_NAME_CAP];
    uint32_t name_len;      // bytes in name[], excluding NUL
    uint32_t objtype;       // VREG / VDIR / VLNK / ...
    uint32_t err;           // per-entry errno, 0 when fine
    uint32_t flags;         // st_flags: SF_DATALESS, UF_COMPRESSED, ...
    uint64_t fileid;        // inode number
    uint32_t nlink;         // hard link count (0 for directories)
    uint32_t entrycount;    // directories only
    int64_t  logical;       // data + resource fork, uncompressed
    int64_t  allocated;     // blocks actually on disk
    int64_t  private_size;  // blocks shared with no other file
    uint64_t cloneid;       // identifies a family of clone-related inodes
    uint32_t clone_refcnt;  // how many inodes are in that family
    uint32_t dev;           // real device, sees through firmlinks
    uint32_t mountstatus;   // DIR_MNTSTATUS_MNTPOINT / _TRIGGER
    uint32_t valid;         // CAD_V_* bitmask
} cad_entry;

// vnode types, re-exported so the Swift side does not depend on how the
// `vtype` enum happens to import.
extern const uint32_t CAD_VREG;
extern const uint32_t CAD_VDIR;
extern const uint32_t CAD_VLNK;

// Must run before the first directory is opened.
//
// MATERIALIZE_DATALESS_FILES_OFF is the one that matters: without it, merely
// reading the attributes of an iCloud-evicted file makes the kernel fetch its
// contents. A scanner that skips this can silently pull hundreds of GB.
// TRIGGER_RESOLVE_OFF keeps us from auto-mounting network shares on the way.
void cad_set_io_policies(void);

// Yield to real work: the scan drops to IOPOL_UTILITY.
void cad_set_low_io_priority(void);

// Real device id of a path, seeing through firmlinks the way
// ATTR_CMNEXT_REALDEVID does, so it can be compared against cad_entry.dev.
// Returns 0 on success, -1 on error (errno set).
int cad_real_device(const char *path, uint32_t *out);

// One getattrlistbulk(2) round on an open directory fd.
//   scratch/scratch_len : kernel reply buffer, reused across calls
//   out/out_cap         : decoded entries
// Returns entries decoded, 0 at end of directory, -1 on error (errno set),
// or -2 if out_cap was too small for the batch (grow it, or shrink scratch).
int cad_bulk(int fd, void *scratch, size_t scratch_len, cad_entry *out, int out_cap);

#endif
