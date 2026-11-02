import Foundation

/// Directories and files flattened into one array, with each node's children
/// stored contiguously.
///
/// The scan keeps directories and files apart because that is what makes it
/// cheap; drawing wants them in one sequence, sorted, with children adjacent so
/// a layout pass is a walk rather than a series of lookups.
final class TreemapModel {
    var name: [String] = []
    var parent: [Int32] = []
    var firstChild: [Int32] = []
    var childCount: [Int32] = []
    /// The laid-out quantity: whichever of the five metrics is on screen.
    var value: [Int64] = []
    var sizes: [Sizes] = []
    var isDirectory: [Bool] = []
    var kind: [Kind] = []
    var depth: [UInt8] = []
    /// Reclaim confidence, propagated down each matched subtree so a whole
    /// `node_modules` lights up rather than only its top rectangle.
    /// 0 regenerable, 1 cache, 2 review, 255 none.
    var reclaimTag: [UInt8] = []
    /// Change in the displayed metric against a loaded baseline. Empty when
    /// there is none. Shown in the inspector.
    var delta: [Int64] = []
    /// Change in blocks actually written, measured on `allocated`.
    ///
    /// This is what the map colours, not `delta`. Cloning a file into another
    /// directory halves the share credited to the original, so a file nobody
    /// opened would otherwise paint itself "shrank" — the same misreading the
    /// text diff had to be taught to annotate. Written bytes have no such
    /// ambiguity: if this is flat, nothing happened here.
    var contentDelta: [Int64] = []
    var hasBaseline: Bool { !delta.isEmpty }

    var count: Int { name.count }

    /// Something on the map that is not in the scanned tree: a sibling volume
    /// of the same APFS container, or the free space. Whole-disk mode adds
    /// these under the root so the map adds up to the disk, not to a folder.
    struct Extra {
        var name: String
        var detail: String
        var bytes: Int64
        var kind: Kind
    }

    /// Synthetic entries carry no path and no context menu.
    func isSynthetic(_ node: Int32) -> Bool {
        kind[Int(node)] == .volume || kind[Int(node)] == .free
    }

    enum Kind: UInt8, CaseIterable {
        case directory, code, image, video, audio, archive, document, data, binary, other
        /// Whole-disk mode only: a volume that shares the container, and the
        /// space nothing occupies.
        case volume, free

        static func of(fileNamed name: String) -> Kind {
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
            switch name[name.index(after: dot)...].lowercased() {
            case "swift", "c", "h", "m", "mm", "cpp", "hpp", "rs", "go", "py", "js", "ts",
                 "tsx", "jsx", "rb", "java", "kt", "sh", "html", "css", "json", "yaml", "yml",
                 "toml", "xml", "sql", "metal": return .code
            case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg", "psd", "raw",
                 "cr2", "nef", "icns", "ktx", "ktx2", "dds", "exr", "hdr", "astc": return .image
            case "mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "prores", "smk",
                 "mpg", "mpeg", "m2ts", "flv", "ogv": return .video
            case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg", "opus",
                 "caf", "mid", "midi": return .audio
            case "zip", "gz", "bz2", "xz", "zst", "tar", "7z", "rar", "dmg", "pkg", "ipa",
                 "jar", "whl": return .archive
            case "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt",
                 "pptx", "md", "txt", "rtf", "rtfd", "epub", "tex", "csv", "log": return .document
            case "db", "sqlite", "sqlite3", "bin", "dat", "pack", "idx", "safetensors",
                 "gguf", "ckpt", "pt", "pth", "onnx", "npz": return .data
            case "o", "a", "so", "dylib", "framework", "app", "exe", "wasm",
                 "rlib", "rmeta", "lib", "dll": return .binary
            default: return .other
            }
        }

        var label: String {
            switch self {
            case .directory: return tr("folder")
            case .code: return tr("code")
            case .image: return tr("image")
            case .video: return tr("video")
            case .audio: return tr("audio")
            case .archive: return tr("archive")
            case .document: return tr("document")
            case .data: return tr("data")
            case .binary: return tr("binary")
            case .other: return tr("other")
            case .volume: return tr("volume")
            case .free: return tr("free space")
            }
        }
    }

    /// Absolute path, rebuilt from the chain of names. Only ever called for one
    /// node at a time — the hovered one, or the one being revealed in Finder.
    func path(of node: Int32) -> String {
        var parts: [String] = []
        var i = node
        while i > 0 {
            parts.append(name[Int(i)])
            i = parent[Int(i)]
        }
        let root = name[0]
        if parts.isEmpty { return root }
        let tail = parts.reversed().joined(separator: "/")
        return root.hasSuffix("/") ? root + tail : root + "/" + tail
    }

    /// Children are emitted contiguously and largest-first: squarified layout
    /// needs descending order to produce square-ish rectangles at all, and
    /// sorting here means the layout pass never has to.
    ///
    /// Ties break on name so that two runs over unchanged data — or two scans
    /// where only unrelated things moved — produce the same picture.
    static func build(from result: ScanResult, metric: Metric,
                      reclaim: [Reclaim.Candidate] = [],
                      baseline: Snapshot? = nil,
                      extras: [Extra] = []) -> TreemapModel {
        let model = TreemapModel()
        let tree = result.tree
        let filesByDirectory = result.files?.groupedByDirectory(directoryCount: tree.count)

        var reclaimTagBySource: [Int32: UInt8] = [:]
        for candidate in reclaim {
            reclaimTagBySource[candidate.node] = UInt8(candidate.rule.confidence.rawValue)
        }

        // Baseline lookups, prepared once: the same name-matched walk the CLI
        // diff does, carried alongside the build so every node lands with its
        // change already attached.
        let baselineFiles = baseline?.files?.groupedByDirectory(
            directoryCount: baseline?.tree.count ?? 0)

        model.append(name: tree.name[Int(result.root)], parent: -1, depth: 0,
                     sizes: tree.total[Int(result.root)], metric: metric,
                     isDirectory: true, kind: .directory)
        if let baseline {
            model.delta.append(metric.value(tree.total[Int(result.root)])
                               - metric.value(baseline.tree.total[Int(baseline.root)]))
            model.contentDelta.append(tree.total[Int(result.root)].allocated
                                      - baseline.tree.total[Int(baseline.root)].allocated)
        }

        // Breadth-first, so that every node's children land side by side.
        var queue: [(model: Int32, source: Int32, baseline: Int32)] = [(0, result.root, baseline?.root ?? -1)]
        var head = 0
        while head < queue.count {
            let (modelIndex, sourceIndex, baselineIndex) = queue[head]
            head += 1

            struct Child {
                var name: String
                var sizes: Sizes
                var isDirectory: Bool
                var source: Int32
                /// The directory names folded into this one, outermost first.
                /// One element for an ordinary directory.
                var chain: [String] = []
                /// Reclaim tag found anywhere along the chain: the outermost
                /// wins, since it is the one the catalogue would offer.
                var reclaimTag: UInt8? = nil
                /// Set for synthetic entries, which are neither files nor folders.
                var kind: Kind? = nil
            }
            // A directory holding nothing but one subdirectory tells the eye
            // nothing and costs a title strip. Chase the chain down and show
            // it as one band — `Cando/Captions/Image/Mais` rather than four
            // nested frames with no content between them.
            //
            // The chain is kept as separate names: the baseline is matched
            // component by component, and a `node_modules` whose only child is
            // `.pnpm` must still carry the catalogue's tag.
            func collapse(_ start: Int32) -> Child {
                var node = start
                var parts = [tree.name[Int(node)]]
                var tag = reclaimTagBySource[node]
                while tree.children[Int(node)].count == 1,
                      filesByDirectory?[Int(node)].isEmpty ?? true {
                    node = tree.children[Int(node)][0]
                    parts.append(tree.name[Int(node)])
                    if tag == nil { tag = reclaimTagBySource[node] }
                }
                return Child(name: parts.joined(separator: "/"), sizes: tree.total[Int(node)],
                             isDirectory: true, source: node, chain: parts, reclaimTag: tag)
            }

            var children: [Child] = []
            for sub in tree.children[Int(sourceIndex)] {
                children.append(collapse(sub))
            }
            if let filesByDirectory, let files = result.files {
                for file in filesByDirectory[Int(sourceIndex)] {
                    children.append(Child(name: files.name[Int(file)], sizes: files.sizes[Int(file)],
                                          isDirectory: false, source: file))
                }
            }

            if modelIndex == 0 {
                for extra in extras where extra.bytes > 0 {
                    var sizes = Sizes()
                    sizes.logical = extra.bytes; sizes.allocated = extra.bytes; sizes.attributed = extra.bytes
                    sizes.exclusive = extra.bytes; sizes.retained = extra.bytes
                    children.append(Child(name: extra.name, sizes: sizes, isDirectory: false, source: -1, kind: extra.kind))
                    model.sizes[0] += sizes
                    model.value[0] += metric.value(sizes)
                }
            }
            children.removeAll { metric.value($0.sizes) <= 0 }
            children.sort {
                let a = metric.value($0.sizes), b = metric.value($1.sizes)
                return a == b ? $0.name < $1.name : a > b
            }
            guard !children.isEmpty else { continue }

            let childDepth = model.depth[Int(modelIndex)] + 1
            model.firstChild[Int(modelIndex)] = Int32(model.count)
            model.childCount[Int(modelIndex)] = Int32(children.count)

            // Name-indexed baseline children, built once per directory.
            var priorDirectories: [String: Int32] = [:]
            var priorFiles: [String: Int32] = [:]
            if let baseline, baselineIndex >= 0 {
                for sub in baseline.tree.children[Int(baselineIndex)] {
                    priorDirectories[baseline.tree.name[Int(sub)]] = sub
                }
                if let baselineFiles, let files = baseline.files {
                    for file in baselineFiles[Int(baselineIndex)] {
                        priorFiles[files.name[Int(file)]] = file
                    }
                }
            }
            /// The baseline node a (possibly collapsed) directory corresponds
            /// to: the first name is looked up among the baseline's children,
            /// the rest are followed down. A chain that was not yet a chain in
            /// the baseline still resolves, since only names are compared.
            func priorDirectory(for child: Child) -> Int32? {
                guard let baseline, let first = child.chain.first, var node = priorDirectories[first] else { return nil }
                for name in child.chain.dropFirst() {
                    guard let next = baseline.tree.children[Int(node)].first(where: { baseline.tree.name[Int($0)] == name })
                    else { return nil }
                    node = next
                }
                return node
            }

            var priorOfChild: [Int32] = []
            priorOfChild.reserveCapacity(children.count)
            for child in children {
                let index = model.append(name: child.name, parent: modelIndex, depth: childDepth,
                                         sizes: child.sizes, metric: metric,
                                         isDirectory: child.isDirectory,
                                         kind: child.kind ?? (child.isDirectory ? .directory : Kind.of(fileNamed: child.name)))
                let inherited = model.reclaimTag[Int(modelIndex)]
                if child.isDirectory, let tag = child.reclaimTag {
                    model.reclaimTag[Int(index)] = tag
                } else if inherited != 255 {
                    model.reclaimTag[Int(index)] = inherited
                }
                let prior: Int32 = child.isDirectory ? (priorDirectory(for: child) ?? -1) : -1
                priorOfChild.append(prior)
                if child.kind != nil {
                    // Synthetic: nothing to compare against, and the reclaim
                    // tag inherited from the root must not stick to it.
                    model.reclaimTag[Int(index)] = 255
                    if baseline != nil { model.delta.append(0); model.contentDelta.append(0) }
                } else if let baseline {
                    var previous = Sizes()
                    if child.isDirectory, prior >= 0 {
                        previous = baseline.tree.total[Int(prior)]
                    } else if !child.isDirectory, let priorFile = priorFiles[child.name],
                              let files = baseline.files {
                        previous = files.sizes[Int(priorFile)]
                    }
                    model.delta.append(metric.value(child.sizes) - metric.value(previous))
                    model.contentDelta.append(child.sizes.allocated - previous.allocated)
                }
            }

            // Recurse only into directories, and only after all siblings exist.
            var cursor = model.firstChild[Int(modelIndex)]
            for (position, child) in children.enumerated() {
                if child.isDirectory {
                    queue.append((cursor, child.source, priorOfChild[position]))
                }
                cursor += 1
            }
        }
        return model
    }

    @discardableResult
    private func append(name n: String, parent p: Int32, depth d: UInt8, sizes s: Sizes,
                        metric: Metric, isDirectory dir: Bool, kind k: Kind) -> Int32 {
        let index = Int32(name.count)
        name.append(n)
        parent.append(p)
        firstChild.append(-1)
        childCount.append(0)
        value.append(metric.value(s))
        sizes.append(s)
        isDirectory.append(dir)
        kind.append(k)
        depth.append(d)
        reclaimTag.append(255)
        return index
    }
}
