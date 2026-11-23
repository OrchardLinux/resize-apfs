import Foundation
import Darwin
import NativeSystem

/// After a grown GPT is written and verified, asks the kernel to read the
/// partition table again (`raf_reprobe_partitions`), so iOS exposes the APFS
/// partition's new size without a restart, then waits up to `deadline` for the
/// partition device to report it. Whatever happens, the grow step itself checks
/// the visible size as before; this only gives it a chance to find it grown.
/// Each attempt is written to the helper log and to reprobe.log in the journal
/// folder, which outlives the iOS 12-14 session's own log.
public enum PartitionReprobe {
    public struct Outcome: Equatable {
        /// raf_reprobe_partitions's result (0: a probe was accepted, else errno).
        public var result: Int32
        /// IOReturn of the partition scheme's and the media's probe; -1: not tried.
        public var schemeStatus: Int32
        public var mediaStatus: Int32
        public var before: UInt64?
        public var after: UInt64?
        public var seconds: Double
        public var reached: Bool
    }

    public struct System {
        public var probe: () -> (result: Int32, scheme: Int32, media: Int32)
        /// The partition device's size in bytes; nil when it cannot be read.
        public var capacity: () -> UInt64?
        public var now: () -> TimeInterval
        public var sleep: (TimeInterval) -> Void
        public init(probe: @escaping () -> (result: Int32, scheme: Int32, media: Int32), capacity: @escaping () -> UInt64?,
                    now: @escaping () -> TimeInterval, sleep: @escaping (TimeInterval) -> Void) {
            self.probe = probe; self.capacity = capacity; self.now = now; self.sleep = sleep
        }
    }

    public static let deadline: TimeInterval = 10
    static let interval: TimeInterval = 0.25

    /// Probes, then waits until the size reaches `target` (nil: until it changes
    /// at all), at most `deadline` seconds. A refused probe is not waited for.
    public static func run(target: UInt64?, using system: System) -> Outcome {
        let start = system.now()
        let before = system.capacity()
        let probe = system.probe()
        var after = system.capacity()
        func done(_ size: UInt64?) -> Bool {
            guard let size else { return false }
            if let target { return size >= target }
            return before.map { size != $0 } ?? false
        }
        if probe.result == 0 {
            let end = system.now() + deadline
            while !done(after) && system.now() < end {
                system.sleep(interval)
                after = system.capacity()
            }
        }
        return Outcome(result: probe.result, schemeStatus: probe.scheme, mediaStatus: probe.media, before: before,
                       after: after, seconds: system.now() - start, reached: done(after))
    }

    public static func describe(_ outcome: Outcome, whole: String, partition: String, target: UInt64?) -> String {
        func hex(_ status: Int32) -> String { status == -1 ? "not tried" : String(format: "0x%08x", UInt32(bitPattern: status)) }
        func size(_ bytes: UInt64?) -> String { bytes.map(String.init) ?? "unreadable" }
        return "Partition reprobe of \(whole): result \(outcome.result) (\(String(cString: strerror(outcome.result)))), "
            + "partition scheme probe \(hex(outcome.schemeStatus)), media probe \(hex(outcome.mediaStatus)); "
            + "\(partition) \(size(outcome.before)) bytes before, \(size(outcome.after)) after"
            + (target.map { ", target \($0)" } ?? "")
            + String(format: ", %.1f s; ", outcome.seconds)
            + (outcome.reached ? "iOS now exposes the new size." : "iOS still exposes the old size.")
    }

    /// The device: `partition` is disk0sN, `whole` its disk.
    public static func device(whole: String, partition: String) -> System {
        System(probe: {
                   var scheme: Int32 = -1, media: Int32 = -1
                   let result = raf_reprobe_partitions(whole, &scheme, &media)
                   return (result, scheme, media)
               },
               capacity: {
                   var bytes: UInt64 = 0
                   return raf_partition_capacity(partition, &bytes) == 0 ? bytes : nil
               },
               now: { ProcessInfo.processInfo.systemUptime },
               sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    /// "disk0" for "disk0s1"; nil for anything that is not diskNsM.
    public static func wholeDisk(of partition: String) -> String? {
        guard partition.hasPrefix("disk") else { return nil }
        let rest = partition.dropFirst(4)
        guard let separator = rest.firstIndex(of: "s") else { return nil }
        let number = rest[..<separator], slice = rest[rest.index(after: separator)...]
        guard !number.isEmpty, number.allSatisfy(\.isASCIIDigit), !slice.isEmpty, slice.allSatisfy(\.isASCIIDigit) else { return nil }
        return "disk" + number
    }

    /// Probes the disk of `partition` (diskNsM), logs and records the outcome.
    @discardableResult
    public static func attempt(partition: String, target: UInt64?, journal directory: URL,
                               log: (String) -> Void = { print($0); fflush(stdout) }) -> Outcome? {
        guard let disk = wholeDisk(of: partition) else {
            log("Resize APFS helper: \(partition) is not a partition device name (diskNsM).")
            return nil
        }
        let outcome = run(target: target, using: device(whole: disk, partition: partition))
        let line = describe(outcome, whole: disk, partition: partition, target: target)
        log("Resize APFS helper: " + line)
        record(line, in: directory)
        return outcome
    }

    /// Appends `line` with the time to reprobe.log (class D, root only).
    public static func record(_ line: String, in directory: URL) {
        let url = directory.appendingPathComponent("reprobe.log")
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: url.path) {
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.none
            #endif
            manager.createFile(atPath: url.path, contents: nil, attributes: attributes)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
