import XCTest
import Foundation
@testable import ResizeCore
import ResizeDevice

struct DiskFixture {
    let url: URL
    let source: DeviceSource
    let containerBytes: Int64 = 32 * 1024 * 1024
    let partitionBytes: Int64 = 48 * 1024 * 1024
    init(directory: URL, sector: Int64 = 4096) throws {
        url = directory.appendingPathComponent("disk.img")
        source = DeviceSource(path: url.path, fixtureSectorSize: sector, writesEnabled: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let totalBytes: Int64 = 64 * 1024 * 1024
        try file.truncate(atOffset: UInt64(totalBytes))
        let total = totalBytes / sector, tableBytes = Int(alignUp(128 * 128, to: sector)), tableBlocks = Int64(tableBytes) / sector
        let firstUsable = 2 + tableBlocks, lastUsable = total - tableBlocks - 2
        let start: Int64 = 256
        var mbr = Data(count: Int(sector))
        mbr[450] = 0xee; mbr.put32(1, at: 454); mbr.put32(UInt32(total - 1), at: 458)
        mbr[510] = 0x55; mbr[511] = 0xaa
        var table = Data(count: tableBytes)
        table.putGPTUUID(UUID(uuidString: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")!, at: 0)
        table.putGPTUUID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, at: 16)
        table.put64(UInt64(firstUsable), at: 32); table.put64(UInt64(start - 1), at: 40)
        table.put64(0x1000000000000000, at: 48)
        table.putGPTUUID(UUID(uuidString: apfsTypeGUID)!, at: 128)
        table.putGPTUUID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, at: 144)
        table.put64(UInt64(start), at: 160); table.put64(UInt64(start + partitionBytes / sector - 1), at: 168)
        for (index, word) in "APFS test".utf16.enumerated() {
            table[184 + index * 2] = UInt8(truncatingIfNeeded: word)
            table[185 + index * 2] = UInt8(truncatingIfNeeded: word >> 8)
        }
        func header(current: Int64, backup: Int64, at: Int64) -> Data {
            var h = Data(count: Int(sector))
            h.replaceSubrange(0..<8, with: "EFI PART".utf8)
            h.put32(0x00010000, at: 8); h.put32(92, at: 12)
            h.put64(UInt64(current), at: 24); h.put64(UInt64(backup), at: 32)
            h.put64(UInt64(firstUsable), at: 40); h.put64(UInt64(lastUsable), at: 48)
            h.putGPTUUID(UUID(uuidString: "00000000-0000-0000-0000-000000000099")!, at: 56)
            h.put64(UInt64(at), at: 72); h.put32(128, at: 80); h.put32(128, at: 84)
            h.put32(DiskChecksums.crc32(Data(table.prefix(128 * 128))), at: 88)
            h.put32(DiskChecksums.crc32(Data(h.prefix(92))), at: 16)
            return h
        }
        func write(_ data: Data, at: Int64) throws { try file.seek(toOffset: UInt64(at)); try file.write(contentsOf: data) }
        try write(mbr, at: 0)
        try write(header(current: 1, backup: total - 1, at: 2), at: sector)
        try write(table, at: sector * 2)
        try write(table, at: sector * (total - tableBlocks - 1))
        try write(header(current: total - 1, backup: 1, at: total - tableBlocks - 1), at: sector * (total - 1))

        let block: Int64 = 4096, blocks = containerBytes / block, xid: UInt64 = 42, smOID: UInt64 = 0x1000
        let volumeID = UUID(uuidString: "00000000-0000-0000-0000-000000000088")!.uuid
        var nxb = Data(count: Int(block))
        nxb.put64(1, at: 8); nxb.put64(xid, at: 16); nxb.put32(0x80000001, at: 24)
        nxb.replaceSubrange(32..<36, with: "NXSB".utf8); nxb.put32(UInt32(block), at: 36); nxb.put64(UInt64(blocks), at: 40)
        nxb.replaceSubrange(72..<88, with: [volumeID.0,volumeID.1,volumeID.2,volumeID.3,volumeID.4,volumeID.5,volumeID.6,volumeID.7,volumeID.8,volumeID.9,volumeID.10,volumeID.11,volumeID.12,volumeID.13,volumeID.14,volumeID.15])
        nxb.put32(8, at: 104); nxb.put64(1, at: 112); nxb.put64(smOID, at: 152)
        var map = Data(count: Int(block))
        map.put64(2, at: 8); map.put64(xid, at: 16); map.put32(0x8000000c, at: 24)
        map.put32(1, at: 32); map.put32(1, at: 36)
        map.put32(0x80000005, at: 40); map.put32(UInt32(block), at: 48)
        map.put64(smOID, at: 64); map.put64(10, at: 72)
        var sm = Data(count: Int(block))
        sm.put64(smOID, at: 8); sm.put64(xid, at: 16); sm.put32(0x80000005, at: 24)
        sm.put32(UInt32(block), at: 32); sm.put64(UInt64(blocks), at: 48); sm.put64(UInt64(blocks - 2048), at: 72)
        try write(Self.seal(nxb), at: start * sector)
        try write(Self.seal(map), at: start * sector + block)
        try write(Self.seal(nxb), at: start * sector + 2 * block)
        try write(Self.seal(sm), at: start * sector + 10 * block)
        try write(Data("Do not alter APFS user data".utf8), at: start * sector + 1_048_576)
        try file.synchronize()
    }
    static func seal(_ data: Data) -> Data {
        var data = data
        let modulus: UInt64 = 0xffffffff
        var a: UInt64 = 0, b: UInt64 = 0
        for at in stride(from: 8, to: data.count, by: 4) {
            a = (a + UInt64(data.le32(at))) % modulus; b = (b + a) % modulus
        }
        let low = (modulus - (a + b) % modulus) % modulus
        let high = (modulus - (a + low) % modulus) % modulus
        data.put64(high << 32 | low, at: 0)
        return data
    }
}

final class DiskBackendTests: XCTestCase {
    func withFixture(_ sector: Int64 = 4096, run: (DiskFixture) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(DiskFixture(directory: directory, sector: sector))
    }
    func testKnownCRCVector() { XCTAssertEqual(DiskChecksums.crc32(Data("123456789".utf8)), 0xcbf43926) }
    func testInspectAPFSAndBothGPTCopies() throws {
        for sector: Int64 in [512, 4096] {
            try withFixture(sector) { fixture in
                let inspected = try DeviceInspector.inspect(fixture.source)
                XCTAssertEqual(inspected.layout.containerBytes, fixture.containerBytes)
                XCTAssertEqual(inspected.layout.backingBytes, fixture.partitionBytes)
                XCTAssertEqual(inspected.layout.allocatedBytes, 8 * 1024 * 1024)
                XCTAssertEqual(inspected.layout.apfs.bsdName, "disk0s2")
                XCTAssertEqual(inspected.transactionID, 42)
                XCTAssertNil(inspected.layout.minimumContainerBytes) // Never invent a minimum.
            }
        }
    }
    func testRealGPTWriterAgainstRegularFilesOnly() throws {
        for sector: Int64 in [512, 4096] {
            try withFixture(sector) { fixture in
                let before = try DeviceInspector.inspect(fixture.source)
                let disk = try RawDisk(fixture.source)
                let sentinelOffset = before.layout.apfs.firstLBA * sector + 1_048_576
                let sentinel = try disk.read(sentinelOffset, 32)
                let plan = try Planner.make(PlanRequest(revision: before.layout.revision, requestedBytes: fixture.containerBytes, createLinux: true), on: before.layout)
                let shrink = DeviceJob(source: fixture.source, step: .shrinkPartition, plan: plan,
                                       expectedGPT: before.gpt, expectedContainerBytes: fixture.containerBytes)
                XCTAssertEqual(DeviceWorker.execute(shrink).outcome, .success)
                let middle = try DeviceInspector.inspect(fixture.source)
                XCTAssertEqual(middle.layout.backingBytes, fixture.containerBytes)
                let create = DeviceJob(source: fixture.source, step: .createLinux, plan: plan,
                                       expectedGPT: middle.gpt, expectedContainerBytes: fixture.containerBytes)
                XCTAssertEqual(DeviceWorker.execute(create).outcome, .success)
                let after = try DeviceInspector.inspect(fixture.source)
                XCTAssertEqual(after.layout.partitions.count, 3)
                XCTAssertEqual(after.gpt.mbr, before.gpt.mbr)
                XCTAssertEqual(after.gpt.primaryTable.prefix(128), before.gpt.primaryTable.prefix(128))
                XCTAssertEqual(try disk.read(sentinelOffset, 32), sentinel)
                XCTAssertEqual(after.layout.apfs.id, before.layout.apfs.id)
                XCTAssertEqual(after.layout.containerID, before.layout.containerID)
            }
        }
    }
    func testStaleOrUnsafeWritesRefusedBeforeMutation() throws {
        try withFixture { fixture in
            let before = try DeviceInspector.inspect(fixture.source)
            let plan = try Planner.make(PlanRequest(revision: before.layout.revision, requestedBytes: fixture.containerBytes, createLinux: false), on: before.layout)
            var job = DeviceJob(source: fixture.source, step: .shrinkPartition, plan: plan,
                                expectedGPT: before.gpt, expectedContainerBytes: fixture.containerBytes)
            job.expectedGPT.primaryHeader[24] ^= 1
            XCTAssertEqual(DeviceWorker.execute(job).outcome, .refused)
            XCTAssertEqual(try RawDisk(fixture.source).gpt(), before.gpt)
            job.expectedGPT = before.gpt
            job.source.writesEnabled = false
            XCTAssertEqual(DeviceWorker.execute(job).outcome, .refused)
        }
    }
    func testCorruptGPTAndAPFSNeverAccepted() throws {
        try withFixture { fixture in
            let disk = try RawDisk(fixture.source)
            let gpt = try disk.gpt()
            let file = try FileHandle(forWritingTo: fixture.url)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(fixture.source.fixtureSectorSize! + 16))
            try file.write(contentsOf: Data([0,0,0,0]))
            XCTAssertThrowsError(try disk.gpt())
            try file.seek(toOffset: UInt64(fixture.source.fixtureSectorSize!))
            try file.write(contentsOf: gpt.primaryHeader)
            let part = try gpt.partitions(diskName: "disk0").first { $0.kind == .apfs }!
            try file.seek(toOffset: UInt64(part.firstLBA * fixture.source.fixtureSectorSize!))
            try file.write(contentsOf: Data(repeating: 0, count: 4096 * 9))
            XCTAssertThrowsError(try DeviceInspector.inspect(fixture.source))
        }
    }
    func testHostNeverOpensPhysicalDiskBackend() {
        XCTAssertThrowsError(try RawDisk(DeviceSource(path: "/dev/disk0", writesEnabled: true)))
    }
    func testGPTBoundsAndAttributePreservation() throws {
        try withFixture { fixture in
            let inspection = try DeviceInspector.inspect(fixture.source)
            let original = inspection.gpt
            XCTAssertThrowsError(try original.changingEnd(partitionID: inspection.layout.apfs.id, to: original.header.lastUsable + 1))
            let updated = try original.changingEnd(partitionID: inspection.layout.apfs.id, to: inspection.layout.apfs.lastLBA - 8)
            XCTAssertEqual(updated.primaryTable[176..<256], original.primaryTable[176..<256])
            XCTAssertEqual(updated.primaryTable.le64(48), 0x1000000000000000)
        }
    }
}
