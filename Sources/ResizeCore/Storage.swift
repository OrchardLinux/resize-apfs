import Foundation

public let linuxTypeGUID = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
public let apfsTypeGUID = "7C3457EF-0000-11AA-AA11-00306543ECAC"

public struct Partition: Codable, Equatable, Identifiable, Sendable {
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
                growthSupported: Bool, issue: String?) {
        self.revision = revision; self.diskID = diskID; self.diskName = diskName; self.deviceName = deviceName
        self.sectorSize = sectorSize; self.totalBlocks = totalBlocks; self.firstUsableLBA = firstUsableLBA
        self.lastUsableLBA = lastUsableLBA; self.partitions = partitions; self.containerID = containerID
        self.backingPartitionID = backingPartitionID; self.containerBytes = containerBytes
        self.allocatedBytes = allocatedBytes; self.minimumContainerBytes = minimumContainerBytes
        self.growthSupported = growthSupported; self.issue = issue
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
        return StorageLayout(revision: UUID(), diskID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                             diskName: "disk0", deviceName: "Simulated storage", sectorSize: sector,
                             totalBlocks: 7_812_500, firstUsableLBA: 6, lastUsableLBA: last,
                             partitions: partitions, containerID: UUID(uuidString: "00000000-0000-0000-0000-000000000088")!,
                             backingPartitionID: apfsID, containerBytes: container, allocatedBytes: 18_400_000_000,
                             minimumContainerBytes: alignDown(20_000_000_000, to: sector), growthSupported: true,
                             issue: scenario == .invalidLayout ? "The simulated primary and backup GPT disagree." : nil)
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
    public static func gb(_ bytes: Int64) -> String {
        (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(0...1))) + " GB"
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
