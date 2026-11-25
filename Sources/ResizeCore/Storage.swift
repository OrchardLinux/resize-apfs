import Foundation

public let linuxTypeGUID = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
public let apfsTypeGUID = "7C3457EF-0000-11AA-AA11-00306543ECAC"

public struct Partition: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case apfs, linux, other }
    public var id: UUID
    public var name: String
    public var bsdName: String
    public var kind: Kind
    public var firstLBA: Int64
    public var lastLBA: Int64
    public var typeGUID: String
    public var contents: String
    public var blocks: Int64 { lastLBA - firstLBA + 1 }

    public init(id: UUID = UUID(), name: String, bsdName: String, kind: Kind,
                firstLBA: Int64, lastLBA: Int64, typeGUID: String, contents: String) {
        self.id = id; self.name = name; self.bsdName = bsdName; self.kind = kind
        self.firstLBA = firstLBA; self.lastLBA = lastLBA
        self.typeGUID = typeGUID; self.contents = contents
    }
}

extension Partition {
    /// Linux partition types by the Discoverable Partitions Specification, as
    /// Orchard's installer writes them (root ARM64, XBOOTLDR) or generic Linux data.
    static let linuxTypeNames: [String: String] = [
        linuxTypeGUID: "Linux",
        "B921B045-1DF0-41C3-AF44-4C6F280D3FAE": "Linux root",
        "BC13C2FF-59E6-4262-A352-B275FD6F7172": "Linux boot",
        "933AC7E1-2EB4-4F13-B844-0E14E2AEF915": "Linux home",
        "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F": "Linux swap",
    ]
    /// Any Linux partition, whichever Linux type it was created with.
    public var isLinux: Bool { kind == .linux || Partition.linuxTypeNames[typeGUID.uppercased()] != nil }
    /// What the user calls it: "Linux root", "APFS", or the GPT name for anything else.
    public var typeName: String {
        if kind == .apfs { return "APFS" }
        if let name = Partition.linuxTypeNames[typeGUID.uppercased()] { return name }
        return name.isEmpty ? "Other partition" : name
    }
    /// The GPT name with the type where they differ: "omarchy-a · Linux root".
    public var label: String {
        let type = typeName
        return name.isEmpty || name == type || kind == .apfs ? type : "\(name) · \(type)"
    }
}

/// The system volume's snapshot that checkra1n's Restore System reverts to
/// ("orig-fs", iOS 12-14). It can keep APFS from shrinking: its blocks stay
/// allocated wherever they sit. nil where there is none to manage (iOS 15+
/// boots from a sealed system snapshot; fixtures; most mock scenarios).
public struct SystemSnapshot: Codable, Equatable, Sendable {
    public var name: String
    /// Whether the snapshot currently exists. Without it the app offers to take one.
    public var present: Bool
    /// False when iOS boots from it or would revert to it; such a snapshot is never removed.
    public var removable: Bool
    /// How much it raises APFS's minimum size, estimated from the on-disk metadata.
    public var heldBytes: Int64?
    public init(name: String = "orig-fs", present: Bool, removable: Bool, heldBytes: Int64? = nil) {
        self.name = name; self.present = present; self.removable = removable; self.heldBytes = heldBytes
    }
}

/// Every APFS volume's snapshots, read from the on-disk metadata, for Technical
/// details. Diagnostic only: nothing is decided from it.
public struct SnapshotVolume: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        /// The volume's boot (root_to) marker points at it: iOS mounts it as the system.
        public var bootsFrom: Bool
        /// The volume's revert (revert_to) marker points at it.
        public var revertsTo: Bool
        /// How much it raises APFS's minimum size; nil when it cannot be estimated.
        public var heldBytes: Int64?
        public init(name: String, bootsFrom: Bool, revertsTo: Bool, heldBytes: Int64?) {
            self.name = name; self.bootsFrom = bootsFrom; self.revertsTo = revertsTo; self.heldBytes = heldBytes
        }
    }
    public var volume: String
    public var role: String
    public var snapshots: [Entry]
    public init(volume: String, role: String, snapshots: [Entry]) {
        self.volume = volume; self.role = role; self.snapshots = snapshots
    }

    /// What a snapshot's markers mean, in the app's words ("" for none).
    public static func markers(_ entry: Entry) -> String {
        [entry.bootsFrom ? "boots from" : nil, entry.revertsTo ? "reverts to" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// One line per snapshot (or "(none)" per volume), for the helper's --snapshots.
    public static func describe(_ volumes: [SnapshotVolume]) -> String {
        var text = ""
        for volume in volumes {
            let title = ["", "None", volume.volume].contains(volume.role) ? volume.volume : "\(volume.volume) (\(volume.role))"
            if volume.snapshots.isEmpty { text += "\(title)  (none)\n"; continue }
            for entry in volume.snapshots {
                let marks = markers(entry)
                let held = entry.heldBytes.map { "holds \(Capacity.gb($0))" } ?? "holds unknown"
                text += "\(title)  \(entry.name)  \(marks.isEmpty ? "-" : marks)  \(held)\n"
            }
        }
        return text
    }
}

public struct StorageLayout: Codable, Equatable, Sendable {
    public var revision: UUID
    public var diskID: UUID
    public var diskName: String
    public var deviceName: String
    public var sectorSize: Int64
    public var totalBlocks: Int64
    public var firstUsableLBA: Int64
    public var lastUsableLBA: Int64
    public var partitions: [Partition]
    public var containerID: UUID
    public var backingPartitionID: UUID
    public var containerBytes: Int64
    public var allocatedBytes: Int64
    // A service-provided limit, NOT inferred from allocated bytes in the UI.
    public var minimumContainerBytes: Int64?
    public var growthSupported: Bool
    public var issue: String?
    /// Absent in records written before snapshots were reported.
    public var systemSnapshot: SystemSnapshot?
    /// All volumes' snapshots (iOS 12-14 devices only); nil where not read.
    public var snapshotVolumes: [SnapshotVolume]?

    public var apfs: Partition { partitions.first { $0.id == backingPartitionID }! }
    public var backingBytes: Int64 { apfs.blocks * sectorSize }
    public var totalBytes: Int64 { totalBlocks * sectorSize }
    public var freeInsideBytes: Int64 { max(0, containerBytes - allocatedBytes) }
    public var followingBoundary: Int64 {
        partitions.filter { $0.firstLBA > apfs.lastLBA }.map(\.firstLBA).min()
            .map { $0 - 1 } ?? lastUsableLBA
    }
    public var maximumBytes: Int64 { (followingBoundary - apfs.firstLBA + 1) * sectorSize }
    public var adjacentFreeBytes: Int64 { maximumBytes - backingBytes }
    public var allUnallocatedBytes: Int64 {
        (lastUsableLBA - firstUsableLBA + 1 - partitions.reduce(0) { $0 + $1.blocks }) * sectorSize
    }

    public init(revision: UUID, diskID: UUID, diskName: String, deviceName: String,
                sectorSize: Int64, totalBlocks: Int64, firstUsableLBA: Int64, lastUsableLBA: Int64,
                partitions: [Partition], containerID: UUID, backingPartitionID: UUID,
                containerBytes: Int64, allocatedBytes: Int64, minimumContainerBytes: Int64?,
                growthSupported: Bool, issue: String?, systemSnapshot: SystemSnapshot? = nil) {
        self.revision = revision; self.diskID = diskID; self.diskName = diskName; self.deviceName = deviceName
        self.sectorSize = sectorSize; self.totalBlocks = totalBlocks; self.firstUsableLBA = firstUsableLBA
        self.lastUsableLBA = lastUsableLBA; self.partitions = partitions; self.containerID = containerID
        self.backingPartitionID = backingPartitionID; self.containerBytes = containerBytes
        self.allocatedBytes = allocatedBytes; self.minimumContainerBytes = minimumContainerBytes
        self.growthSupported = growthSupported; self.issue = issue; self.systemSnapshot = systemSnapshot
    }

    public func validate() throws {
        if let issue { throw ResizeError(issue) }
        guard sectorSize >= 512, sectorSize <= 65_536, sectorSize.nonzeroBitCount == 1,
              totalBlocks > 0, totalBlocks <= Int64.max / sectorSize,
              firstUsableLBA >= 0, firstUsableLBA <= lastUsableLBA,
              lastUsableLBA < totalBlocks else { throw ResizeError("Invalid disk geometry.") }
        let sorted = partitions.sorted { $0.firstLBA < $1.firstLBA }
        var previous = firstUsableLBA - 1
        var identities = Set<UUID>()
        for partition in sorted {
            guard partition.firstLBA > previous, partition.lastLBA >= partition.firstLBA,
                  partition.lastLBA <= lastUsableLBA, identities.insert(partition.id).inserted
            else { throw ResizeError("Partition boundaries overlap or are invalid.") }
            previous = partition.lastLBA
        }
        guard let backing = partitions.first(where: { $0.id == backingPartitionID }),
              backing.kind == .apfs, backing.typeGUID.uppercased() == apfsTypeGUID,
              containerBytes > 0, containerBytes % sectorSize == 0,
              containerBytes <= backing.blocks * sectorSize,
              allocatedBytes >= 0, allocatedBytes <= containerBytes
        else { throw ResizeError("APFS does not fit inside its identified backing partition.") }
    }

    public static func fixture(_ scenario: MockScenario = .normal) -> StorageLayout {
        let sector: Int64 = 4096
        let start: Int64 = 97_656
        let last: Int64 = 7_812_494
        let apfsID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let reduced = [.freeSpace, .linuxBlocked].contains(scenario)
        let snapshotted = [.snapshot, .snapshotProtected].contains(scenario)
        let container: Int64 = (reduced || scenario == .mismatch) ? 24_000_000_000 : (last - start + 1) * sector
        let partitionEnd = reduced ? start + container / sector - 1 : last
        var partitions = [
            Partition(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                      name: "Other", bsdName: "disk0s1", kind: .other, firstLBA: 6,
                      lastLBA: start - 1, typeGUID: "SIMULATED", contents: "Simulated system partition"),
            Partition(id: apfsID, name: "Container", bsdName: "disk0s2", kind: .apfs,
                      firstLBA: start, lastLBA: partitionEnd, typeGUID: apfsTypeGUID, contents: "APFS")
        ]
        if scenario == .linuxBlocked {
            partitions.append(Partition(name: "Linux", bsdName: "disk0s3", kind: .linux,
                                        firstLBA: alignUp(partitionEnd + 1, to: 8), lastLBA: last,
                                        typeGUID: linuxTypeGUID, contents: "Unformatted (simulated)"))
        }
        var layout = StorageLayout(revision: UUID(), diskID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                             diskName: "disk0", deviceName: "Simulated storage", sectorSize: sector,
                             totalBlocks: 7_812_500, firstUsableLBA: 6, lastUsableLBA: last,
                             partitions: partitions, containerID: UUID(uuidString: "00000000-0000-0000-0000-000000000088")!,
                             backingPartitionID: apfsID, containerBytes: container, allocatedBytes: 18_400_000_000,
                             minimumContainerBytes: alignDown(snapshotted ? 29_600_000_000 : 20_000_000_000, to: sector), growthSupported: true,
                             issue: scenario == .invalidLayout ? "The simulated primary and backup GPT disagree." : nil,
                             systemSnapshot: snapshotted ? SystemSnapshot(present: true, removable: scenario == .snapshot,
                                                                          heldBytes: scenario == .snapshot ? 10_100_000_000 : nil) : nil)
        if snapshotted {
            layout.snapshotVolumes = mockSnapshotVolumes(orig: SnapshotVolume.Entry(name: "orig-fs", bootsFrom: scenario != .snapshot, revertsTo: false,
                                                                                   heldBytes: scenario == .snapshot ? 10_100_000_000 : nil))
        }
        return layout
    }

    /// The mock's Technical details list: orig-fs (or none) on System, Data without snapshots.
    public static func mockSnapshotVolumes(orig: SnapshotVolume.Entry?) -> [SnapshotVolume] {
        [SnapshotVolume(volume: "System", role: "System", snapshots: orig.map { [$0] } ?? []),
         SnapshotVolume(volume: "Data", role: "None", snapshots: [])]
    }
}

public struct ResizeError: Error, LocalizedError, Equatable, Codable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public func alignDown(_ value: Int64, to alignment: Int64) -> Int64 { value / alignment * alignment }
public func alignUp(_ value: Int64, to alignment: Int64) -> Int64 {
    value % alignment == 0 ? value : (value / alignment + 1) * alignment
}

public enum Capacity {
    /// Same output as the iOS 15 `.formatted(.number.precision(.fractionLength(0...1)))`
    /// it replaces: the current locale's separators, grouping, at most one decimal,
    /// rounded half-to-even.
    public static func gb(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfEven
        let value = Double(bytes) / 1_000_000_000
        return (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)) + " GB"
    }
    public static func input(_ bytes: Int64) -> String {
        NSDecimalNumber(decimal: Decimal(bytes) / 1_000_000_000).stringValue
    }
    public static func parseGB(_ text: String) -> Int64? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, normalized.contains(where: { $0.isNumber }),
              normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              normalized.filter({ $0 == "." }).count <= 1,
              let number = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), number >= 0,
              number <= Decimal(Int64.max) / 1_000_000_000 else { return nil }
        let bytes = number * 1_000_000_000
        return NSDecimalNumber(decimal: bytes).int64Value
    }
}
