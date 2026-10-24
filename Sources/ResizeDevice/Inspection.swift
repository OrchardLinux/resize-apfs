import Foundation
import Darwin
import CryptoKit
import ResizeCore
import NativeSystem

public struct DeviceSource: Codable, Equatable, Sendable {
    public var path: String
    public var fixtureSectorSize: Int64?
    public var writesEnabled: Bool
    public init(path: String = "/dev/disk0", fixtureSectorSize: Int64? = nil, writesEnabled: Bool = false) {
        self.path = path; self.fixtureSectorSize = fixtureSectorSize; self.writesEnabled = writesEnabled
    }
    public var isFixture: Bool { fixtureSectorSize != nil }
}

public final class RawDisk {
    public let fd: Int32
    public let source: DeviceSource
    public let sectorSize: Int64
    public let totalBlocks: Int64
    public init(_ source: DeviceSource) throws {
        self.source = source
        let descriptor = raf_open_read(source.path, source.isFixture ? 1 : 0)
        guard descriptor >= 0 else { throw ResizeError("Cannot open the selected disk read-only: \(String(cString: strerror(errno))).") }
        do {
            if let sector = source.fixtureSectorSize {
                var st = stat()
                guard sector >= 512, sector <= 65536, sector.nonzeroBitCount == 1,
                      fstat(descriptor, &st) == 0, st.st_size > 0, st.st_size % sector == 0 else {
                    throw ResizeError("Invalid regular-file disk fixture.")
                }
                sectorSize = sector; totalBlocks = st.st_size / sector
            } else {
                var size: UInt32 = 0, count: UInt64 = 0
                guard raf_geometry(descriptor, &size, &count) == 0, size >= 512,
                      count > 64, count <= UInt64(Int64.max) / UInt64(size) else {
                    throw ResizeError("The disk geometry could not be established.")
                }
                sectorSize = Int64(size); totalBlocks = Int64(count)
            }
        } catch { close(descriptor); throw error }
        fd = descriptor
    }
    deinit { close(fd) }

    public func read(_ offset: Int64, _ length: Int) throws -> Data {
        guard offset >= 0, length > 0, length <= 64 * 1024 * 1024,
              offset <= sectorSize * totalBlocks - Int64(length) else { throw ResizeError("Metadata read is outside the disk bounds.") }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < length {
                let n = pread(fd, buffer.baseAddress!.advanced(by: done), length - done, off_t(offset + Int64(done)))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ResizeError("A metadata read failed or was incomplete.") }
                done += n
            }
        }
        return data
    }
    public func gpt() throws -> GPTImage {
        try GPTImage.capture(sectorSize: sectorSize, totalBlocks: totalBlocks, read: read)
    }
}

public struct DeviceInspection: Codable, Sendable {
    public var layout: StorageLayout
    public var gpt: GPTImage
    public var observedAt: Date
    public var transactionID: UInt64
}

public enum DeviceInspector {
    /// Blocking APFS/device reads must not consume Swift cooperative-executor
    /// threads needed by the independent worker monitor and status RPCs.
    public static func inspectAsync(_ source: DeviceSource, queryMinimum: Bool = true) async throws -> DeviceInspection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try inspect(source, queryMinimum: queryMinimum)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public static func inspect(_ source: DeviceSource, queryMinimum: Bool = true) throws -> DeviceInspection {
        let disk = try RawDisk(source)
        let gpt = try disk.gpt()
        let parts = try gpt.partitions(diskName: "disk0")
        let containers = parts.filter { $0.kind == .apfs }
        guard containers.count == 1, let part = containers.first else {
            throw ResizeError("This helper currently requires exactly one APFS physical-store partition on disk0.")
        }
        let partBytes = part.blocks * disk.sectorSize
        let metadata = try APFSMetadata.capture(partitionBytes: partBytes) { offset, length in
            guard offset >= 0, offset <= partBytes - Int64(length) else { throw ResizeError("APFS metadata exceeds its backing partition.") }
            return try disk.read(part.firstLBA * disk.sectorSize + offset, length)
        }
        var minimum: Int64?
        if queryMinimum && source.writesEnabled && !source.isFixture {
            var bytes: Int64 = 0
            if raf_apfs_minimum(part.bsdName, &bytes) == 0,
               bytes >= metadata.allocatedBytes, bytes > 0, bytes <= metadata.capacityBytes,
               bytes % max(4096, disk.sectorSize) == 0 { minimum = bytes }
        }
        let identity = gpt.primaryHeader + gpt.primaryTable + Data("\(metadata.containerID):\(metadata.capacityBytes)".utf8)
        let digest = Data(SHA256.hash(data: identity))
        var layout = StorageLayout(revision: digest.gptUUID(at: 0)!, diskID: gpt.header.diskID,
                                   diskName: "disk0", deviceName: source.isFixture ? "Regular-file fixture" : machineName(),
                                   sectorSize: disk.sectorSize, totalBlocks: disk.totalBlocks,
                                   firstUsableLBA: gpt.header.firstUsable, lastUsableLBA: gpt.header.lastUsable,
                                   partitions: parts, containerID: metadata.containerID, backingPartitionID: part.id,
                                   containerBytes: metadata.capacityBytes, allocatedBytes: metadata.allocatedBytes,
                                   minimumContainerBytes: minimum, growthSupported: source.writesEnabled && !source.isFixture, issue: nil)
        try layout.validate()
        if !source.writesEnabled { layout.issue = "Inspection only. This overlay was built without storage-write permission." }
        return DeviceInspection(layout: layout, gpt: gpt, observedAt: Date(), transactionID: metadata.transactionID)
    }

    private static func machineName() -> String {
        var length = 0
        guard sysctlbyname("hw.machine", nil, &length, nil, 0) == 0, length > 0, length < 256 else { return "Device" }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.machine", &buffer, &length, nil, 0) == 0 else { return "Device" }
        return String(cString: buffer)
    }
}

public enum DeviceJournal {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ResizeError("Cannot confirm the operation journal was saved.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ResizeError("Cannot synchronize the operation journal.") }
    }
}
