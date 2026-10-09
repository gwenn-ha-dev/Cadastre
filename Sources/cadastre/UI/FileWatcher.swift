import Foundation
import CoreServices

/// Tells the window that something under a folder changed.
///
/// FSEvents reports the directories whose contents moved, coalesced by the
/// kernel over `latency` seconds. What follows is deliberately not an
/// incremental patch of the tree: clone families and retained bytes are
/// settled over the whole scan, and a tree patched one directory at a time
/// would slowly drift from the disk. The trigger is incremental; the measure
/// is redone, in the background, and the previous measure becomes the marker
/// so the map colours exactly what just moved.
///
/// `@unchecked Sendable`: the FSEvents callback only hops to the main queue,
/// where `onChange` runs and where the window starts and stops the stream.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "cadastre.watcher", qos: .utility)
    private let onChange: @MainActor () -> Void

    init(path: String, latency: TimeInterval = 2, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
