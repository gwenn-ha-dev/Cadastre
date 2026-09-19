import Foundation

/// Blocks that belong to more than one name.
///
/// Two different mechanisms produce them and both must be handled or the
/// totals are wrong: hard links (several directory entries, one inode) and
/// APFS clones (several inodes, one set of extents). `du` handles the first
/// and ignores the second, which is why it reports a Mac full of Xcode builds
/// and Time Machine local copies as far fuller than it is.
struct Families {
    struct Inode {
        var nlink: UInt32
        var seen: UInt32 = 0      // directory entries encountered so far
        var lca: Int32 = -1
        /// Directories holding this inode's links. Needed to decide whether an
        /// arbitrary set of deletions — not just one subtree — frees it.
        var nodes: [Int32] = []
        var exclusive: Int64      // blocks shared with no other inode
        var shared: Int64         // blocks shared with the rest of the clone family
        var cloneID: UInt64
        var refcount: UInt32
    }

    struct Clone {
        var refcount: UInt32      // inodes in the family, per the filesystem
        var members: Set<UInt64> = []
        var lca: Int32 = -1
        var nodes: [Int32] = []
        var shared: Int64 = 0     // family's shared extents, taken as the max
    }

    var inodes: [UInt64: Inode] = [:]
    var clones: [UInt64: Clone] = [:]

    /// Record one directory entry that is either hard-linked or cloned.
    /// Plain files never reach here; they are accounted directly.
    ///
    /// Everything noted into a given instance comes from a single directory,
    /// so no ancestor arithmetic is needed — and none may be attempted, since
    /// this runs on a worker thread while the tree is being appended to
    /// elsewhere. Cross-directory merging happens later, under the lock.
    mutating func note(fileID: UInt64, nlink: UInt32, exclusive: Int64, shared: Int64,
                       cloneID: UInt64, refcount: UInt32, node: Int32) {
        if var inode = inodes[fileID] {
            inode.seen += 1
            inode.nodes.append(node)
            inodes[fileID] = inode
        } else {
            inodes[fileID] = Inode(nlink: max(nlink, 1), seen: 1, lca: node, nodes: [node],
                                   exclusive: exclusive, shared: shared,
                                   cloneID: cloneID, refcount: refcount)
        }

        guard refcount > 1, cloneID != 0 else { return }
        var clone = clones[cloneID] ?? Clone(refcount: refcount)
        clone.members.insert(fileID)
        clone.refcount = max(clone.refcount, refcount)
        clone.shared = max(clone.shared, shared)
        clone.lca = node
        clone.nodes.append(node)
        clones[cloneID] = clone
    }

    mutating func merge(_ other: Families, tree: Tree) {
        for (id, incoming) in other.inodes {
            if var existing = inodes[id] {
                existing.seen += incoming.seen
                existing.lca = tree.lca(existing.lca, incoming.lca)
                existing.nodes.append(contentsOf: incoming.nodes)
                inodes[id] = existing
            } else {
                inodes[id] = incoming
            }
        }
        for (id, incoming) in other.clones {
            if var existing = clones[id] {
                existing.members.formUnion(incoming.members)
                existing.refcount = max(existing.refcount, incoming.refcount)
                existing.shared = max(existing.shared, incoming.shared)
                existing.lca = tree.lca(existing.lca, incoming.lca)
                existing.nodes.append(contentsOf: incoming.nodes)
                clones[id] = existing
            } else {
                clones[id] = incoming
            }
        }
    }

    struct Settlement {
        /// Bytes that only become free once a whole subtree goes, credited to
        /// the deepest directory that contains the entire family.
        var retainedAt: [Int32: Int64] = [:]
        /// Families straddling the scan boundary: we saw some members but not
        /// all, so no directory inside the scan can claim their blocks.
        var reachesOutside: Int64 = 0
        var straddlingFamilies: Int = 0
    }

    /// Decide, for every shared-block family, which directory actually owns it.
    ///
    /// A family is *contained* in directory D when every one of its members
    /// lives under D. The deepest such D is the lowest common ancestor of the
    /// members, so crediting the LCA and then rolling up gives every ancestor
    /// the right answer at once.
    func settle(tree: Tree) -> Settlement {
        var result = Settlement()

        for (_, inode) in inodes {
            guard inode.exclusive > 0 else { continue }
            if inode.seen >= inode.nlink {
                result.retainedAt[inode.lca, default: 0] += inode.exclusive
            } else {
                result.reachesOutside += inode.exclusive
                result.straddlingFamilies += 1
            }
        }

        for (_, clone) in clones {
            guard clone.shared > 0 else { continue }
            let complete = clone.members.count >= Int(clone.refcount)
                && clone.members.allSatisfy { id in
                    guard let inode = inodes[id] else { return false }
                    return inode.seen >= inode.nlink
                }
            if complete {
                result.retainedAt[clone.lca, default: 0] += clone.shared
            } else {
                result.reachesOutside += clone.shared
                result.straddlingFamilies += 1
            }
        }

        return result
    }
}

extension Families {
    /// Bytes freed by deleting an arbitrary set of subtrees at once.
    ///
    /// Not the sum of each subtree's `retained`: two directories can share
    /// blocks with each other — pnpm hard-links every project's dependencies
    /// into one store, so removing a single `node_modules` frees almost
    /// nothing while removing all of them frees a lot. A family counts only
    /// when every one of its members falls inside the set.
    func bytesFreed(deleting marked: [Bool], plainBytes: [Int64]) -> Int64 {
        var total: Int64 = 0
        for node in 0..<marked.count where marked[node] {
            total += plainBytes[node]
        }

        func allInside(_ nodes: [Int32]) -> Bool {
            nodes.allSatisfy { $0 >= 0 && Int($0) < marked.count && marked[Int($0)] }
        }

        for (_, inode) in inodes where inode.exclusive > 0 {
            if inode.seen >= inode.nlink && allInside(inode.nodes) {
                total += inode.exclusive
            }
        }
        for (_, clone) in clones where clone.shared > 0 {
            let complete = clone.members.count >= Int(clone.refcount)
                && clone.members.allSatisfy { inodes[$0].map { $0.seen >= $0.nlink } ?? false }
            if complete && allInside(clone.nodes) {
                total += clone.shared
            }
        }
        return total
    }
}
