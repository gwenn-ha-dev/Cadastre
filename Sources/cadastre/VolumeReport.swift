import Foundation

/// Everything about free space that a directory walk cannot tell you.
///
/// The gap between "sum of the files" and "what the disk says" is where most
/// of macOS's disk-space confusion lives: snapshots pinning deleted data,
/// purgeable caches the OS will drop under pressure, sibling volumes in the
/// same APFS container that no scanner ever visits.
struct VolumeReport {
    struct Volume {
        var name: String
        var device: String
        var roles: [String]
        var used: Int64
        var mountPoint: String?
    }

    struct Container {
        var reference: String
        var ceiling: Int64
        var free: Int64
        var volumes: [Volume]
        var accountedUsed: Int64 { volumes.reduce(0) { $0 + $1.used } }
    }

    var mountPoint: String = "/"
    var totalCapacity: Int64 = 0
    var availableRaw: Int64 = 0          // statfs, before macOS is helpful
    var availableForImportant: Int64 = 0 // includes what macOS would purge
    var availableForOpportunistic: Int64 = 0
    var snapshots: [String] = []
    var containers: [Container] = []
    var hasFullDiskAccess = false

    /// Space macOS counts as free only because it is prepared to throw
    /// something away first. Deleting files does not add to it.
    var purgeable: Int64 { max(0, availableForImportant - availableRaw) }

    static func gather(for path: String) -> VolumeReport {
        var report = VolumeReport()

        var fs = statfs()
        if statfs(path, &fs) == 0 {
            report.mountPoint = withUnsafeBytes(of: &fs.f_mntonname) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let blockSize = Int64(fs.f_bsize)
            report.totalCapacity = Int64(fs.f_blocks) * blockSize
            report.availableRaw = Int64(fs.f_bavail) * blockSize
        }

        let url = URL(fileURLWithPath: report.mountPoint)
        if let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeTotalCapacityKey,
        ]) {
            report.availableForImportant = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            report.availableForOpportunistic = Int64(values.volumeAvailableCapacityForOpportunisticUsage ?? 0)
            if let total = values.volumeTotalCapacity, report.totalCapacity == 0 {
                report.totalCapacity = Int64(total)
            }
        }

        report.snapshots = localSnapshots(of: report.mountPoint)
        report.containers = apfsContainers()
        report.hasFullDiskAccess = probeFullDiskAccess()
        return report
    }

    /// Deleting a file that a snapshot still references frees nothing until
    /// the snapshot expires, which is the single most common reason a cleanup
    /// session appears to accomplish nothing.
    private static func localSnapshots(of mountPoint: String) -> [String] {
        guard let output = run("/usr/bin/tmutil", ["listlocalsnapshots", mountPoint]) else { return [] }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }

    /// Preboot, Recovery and VM live in the same container and consume the
    /// same pool of free space, but sit outside every mounted path a scanner
    /// would walk. On a typical Mac they hold north of ten gigabytes.
    private static func apfsContainers() -> [Container] {
        guard let data = runData("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let raw = root["Containers"] as? [[String: Any]]
        else { return [] }

        let mounts = mountPointsByDevice()
        return raw.map { entry in
            let volumes = (entry["Volumes"] as? [[String: Any]] ?? []).map { volume -> Volume in
                let device = volume["DeviceIdentifier"] as? String ?? "?"
                return Volume(
                    name: volume["Name"] as? String ?? "?",
                    device: device,
                    roles: volume["Roles"] as? [String] ?? [],
                    used: (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0,
                    mountPoint: mounts[device]
                )
            }
            return Container(
                reference: entry["ContainerReference"] as? String ?? "?",
                ceiling: (entry["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0,
                free: (entry["CapacityFree"] as? NSNumber)?.int64Value ?? 0,
                volumes: volumes
            )
        }
    }

    private static func mountPointsByDevice() -> [String: String] {
        var result: [String: String] = [:]
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let list = buffer else { return result }
        for i in 0..<Int(count) {
            var entry = list[i]
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            result[(from as NSString).lastPathComponent] = on
        }
        return result
    }

    /// Without Full Disk Access, Mail, Messages, Safari and the iOS backups
    /// simply read as empty. A scanner that does not say so reports a tidy
    /// home folder and quietly hides tens of gigabytes.
    private static func probeFullDiskAccess() -> Bool {
        let canary = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(canary, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM && errno != EACCES
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        guard let data = runData(tool, arguments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func runData(_ tool: String, _ arguments: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
