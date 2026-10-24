import Foundation

public enum DiskChecksums {
    public static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
    public static func validAPFSObject(_ bytes: Data) -> Bool {
        guard bytes.count >= 32, bytes.count % 4 == 0 else { return false }
        let modulus: UInt64 = 0xffffffff
        var a: UInt64 = 0, b: UInt64 = 0
        for offset in stride(from: 8, to: bytes.count, by: 4) {
            a = (a + UInt64(bytes.le32(offset))) % modulus
            b = (b + a) % modulus
        }
        let low = (modulus - ((a + b) % modulus)) % modulus
        let high = (modulus - ((a + low) % modulus)) % modulus
        return bytes.le64(0) == (high << 32) | low
    }
}

extension Data {
    public func le32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << ($1 * 8) }
    }
    public func le64(_ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + offset + $1]) << ($1 * 8) }
    }
    public mutating func put32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    public mutating func put64(_ value: UInt64, at offset: Int) {
        for i in 0..<8 { self[startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    public func gptUUID(at offset: Int) -> UUID? {
        guard offset >= 0, count >= offset + 16 else { return nil }
        let b = Array(self[offset..<(offset + 16)])
        return UUID(uuid: (b[3],b[2],b[1],b[0],b[5],b[4],b[7],b[6],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    public mutating func putGPTUUID(_ uuid: UUID, at offset: Int) {
        let u = uuid.uuid
        let bytes: [UInt8] = [u.3,u.2,u.1,u.0,u.5,u.4,u.7,u.6,u.8,u.9,u.10,u.11,u.12,u.13,u.14,u.15]
        replaceSubrange(offset..<(offset + 16), with: bytes)
    }
}

public struct GPTHeader: Codable, Equatable, Sendable {
    public let current: Int64
    public let backup: Int64
    public let firstUsable: Int64
    public let lastUsable: Int64
    public let diskID: UUID
    public let tableLBA: Int64
    public let entryCount: Int
    public let tableCRC: UInt32
    public let size: Int

    public static func parse(_ data: Data, sectorSize: Int64, totalBlocks: Int64) throws -> GPTHeader {
        guard data.count == sectorSize, data.prefix(8) == Data("EFI PART".utf8), data.le32(8) == 0x00010000 else {
            throw ResizeError("Missing or unsupported GPT header.")
        }
        let size = Int(data.le32(12)), count = Int(data.le32(80))
        guard size >= 92, size <= data.count, count > 0, count <= 4096, data.le32(84) == 128,
              let diskID = data.gptUUID(at: 56) else { throw ResizeError("Unsupported GPT header geometry.") }
        var header = Data(data.prefix(size)); header.put32(0, at: 16)
        guard DiskChecksums.crc32(header) == data.le32(16) else { throw ResizeError("GPT header checksum does not match.") }
        let fields = [24,32,40,48,72].map { data.le64($0) }
        guard fields.allSatisfy({ $0 < UInt64(totalBlocks) }), fields[2] <= fields[3] else {
            throw ResizeError("GPT boundaries extend outside the disk.")
        }
        return GPTHeader(current: Int64(fields[0]), backup: Int64(fields[1]), firstUsable: Int64(fields[2]),
                         lastUsable: Int64(fields[3]), diskID: diskID, tableLBA: Int64(fields[4]),
                         entryCount: count, tableCRC: data.le32(88), size: size)
    }
}

public struct GPTImage: Codable, Equatable, Sendable {
    public typealias Reader = (Int64, Int) throws -> Data // byte offset, exact byte count
    public var sectorSize: Int64
    public var totalBlocks: Int64
    public var mbr: Data
    public var primaryHeader: Data
    public var backupHeader: Data
    public var primaryTable: Data
    public var backupTable: Data
    public var header: GPTHeader
    public var secondary: GPTHeader

    public static func capture(sectorSize: Int64, totalBlocks: Int64, read: Reader) throws -> GPTImage {
        guard sectorSize >= 512, sectorSize <= 65536, sectorSize.nonzeroBitCount == 1,
              totalBlocks > 64, totalBlocks <= Int64.max / sectorSize else { throw ResizeError("Invalid disk sector geometry.") }
        let mbr = try read(0, Int(sectorSize))
        guard mbr.count == sectorSize, mbr[510] == 0x55, mbr[511] == 0xaa else { throw ResizeError("Invalid protective MBR.") }
        var types: [UInt8] = []
        for index in 0..<4 {
            let type: UInt8 = mbr[450 + index * 16]
            if type != 0 { types.append(type) }
        }
        guard types == [0xee] else { throw ResizeError("Hybrid or missing protective MBR is not supported.") }
        let primary = try read(sectorSize, Int(sectorSize))
        let backup = try read((totalBlocks - 1) * sectorSize, Int(sectorSize))
        let h = try GPTHeader.parse(primary, sectorSize: sectorSize, totalBlocks: totalBlocks)
        let b = try GPTHeader.parse(backup, sectorSize: sectorSize, totalBlocks: totalBlocks)
        let bytes = h.entryCount * 128
        let tableBytes = Int(alignUp(Int64(bytes), to: sectorSize))
        let blocks = Int64(tableBytes) / sectorSize
        guard h.current == 1, h.backup == totalBlocks - 1, b.current == h.backup, b.backup == 1,
              h.diskID == b.diskID, h.entryCount == b.entryCount,
              h.firstUsable == b.firstUsable, h.lastUsable == b.lastUsable,
              h.tableLBA >= 2, h.tableLBA + blocks <= h.firstUsable,
              b.tableLBA > h.lastUsable, b.tableLBA + blocks <= b.current else {
            throw ResizeError("Primary and backup GPT geometry disagree.")
        }
        let firstTable = try read(h.tableLBA * sectorSize, tableBytes)
        let secondTable = try read(b.tableLBA * sectorSize, tableBytes)
        guard firstTable.count == tableBytes, secondTable.count == tableBytes,
              DiskChecksums.crc32(Data(firstTable.prefix(bytes))) == h.tableCRC,
              DiskChecksums.crc32(Data(secondTable.prefix(bytes))) == b.tableCRC,
              firstTable.prefix(bytes) == secondTable.prefix(bytes),
              try read(sectorSize, Int(sectorSize)) == primary else {
            throw ResizeError("GPT tables disagree, changed during inspection, or have invalid checksums.")
        }
        return GPTImage(sectorSize: sectorSize, totalBlocks: totalBlocks, mbr: mbr,
                        primaryHeader: primary, backupHeader: backup, primaryTable: firstTable,
                        backupTable: secondTable, header: h, secondary: b)
    }

    public func partitions(diskName: String) throws -> [Partition] {
        var result: [Partition] = []
        for index in 0..<header.entryCount {
            let at = index * 128
            guard primaryTable[at..<(at + 16)].contains(where: { $0 != 0 }) else { continue }
            guard let type = primaryTable.gptUUID(at: at), let id = primaryTable.gptUUID(at: at + 16),
                  primaryTable.le64(at + 32) <= UInt64(Int64.max), primaryTable.le64(at + 40) <= UInt64(Int64.max) else {
                throw ResizeError("Invalid GPT partition entry.")
            }
            let first = Int64(primaryTable.le64(at + 32)), last = Int64(primaryTable.le64(at + 40))
            guard first >= header.firstUsable, last >= first, last <= header.lastUsable else { throw ResizeError("Invalid GPT partition boundary.") }
            var words: [UInt16] = []
            for offset in stride(from: at + 56, to: at + 128, by: 2) {
                let word = UInt16(primaryTable[offset]) | UInt16(primaryTable[offset + 1]) << 8
                if word == 0 { break }; words.append(word)
            }
            let kind: Partition.Kind = type.uuidString == apfsTypeGUID ? .apfs : type.uuidString == linuxTypeGUID ? .linux : .other
            result.append(Partition(id: id, name: String(decoding: words, as: UTF16.self), bsdName: "\(diskName)s\(index + 1)",
                                    kind: kind, firstLBA: first, lastLBA: last, typeGUID: type.uuidString,
                                    contents: kind == .apfs ? "APFS" : "Not inspected"))
        }
        let sorted = result.sorted { $0.firstLBA < $1.firstLBA }
        for pair in zip(sorted, sorted.dropFirst()) where pair.0.lastLBA >= pair.1.firstLBA {
            throw ResizeError("GPT partitions overlap.")
        }
        guard Set(result.map(\.id)).count == result.count else { throw ResizeError("Duplicate GPT partition GUIDs.") }
        return result
    }

    /// Change only an identified end boundary and/or add one new entry.
    /// All unrelated entry bytes, attributes, names, GUIDs and MBR remain untouched.
    public func changingEnd(partitionID: UUID, to lastLBA: Int64, adding: Partition? = nil) throws -> GPTImage {
        var image = self
        let parts = try partitions(diskName: "disk0")
        guard let selected = parts.first(where: { $0.id == partitionID }),
              lastLBA >= selected.firstLBA, lastLBA <= header.lastUsable,
              let index = (0..<header.entryCount).first(where: { primaryTable.gptUUID(at: $0 * 128 + 16) == partitionID })
        else { throw ResizeError("The selected partition changed or has an unsafe target.") }
        image.primaryTable.put64(UInt64(lastLBA), at: index * 128 + 40)
        if let adding {
            guard adding.kind == .linux, adding.typeGUID.uppercased() == linuxTypeGUID,
                  adding.firstLBA > lastLBA, adding.lastLBA >= adding.firstLBA,
                  adding.lastLBA <= header.lastUsable, adding.name == "Linux",
                  !parts.contains(where: { $0.id == adding.id }),
                  let slot = (0..<header.entryCount).first(where: {
                      image.primaryTable[($0 * 128)..<($0 * 128 + 128)].allSatisfy { $0 == 0 }
                  }) else { throw ResizeError("Cannot safely create the requested Linux partition.") }
            guard adding.bsdName == "disk0s\(slot + 1)" else {
                throw ResizeError("The reviewed Linux entry does not match an entirely empty GPT slot.")
            }
            let at = slot * 128
            image.primaryTable.putGPTUUID(UUID(uuidString: linuxTypeGUID)!, at: at)
            image.primaryTable.putGPTUUID(adding.id, at: at + 16)
            image.primaryTable.put64(UInt64(adding.firstLBA), at: at + 32)
            image.primaryTable.put64(UInt64(adding.lastLBA), at: at + 40)
            let name = Array("Linux".utf16)
            for (i, word) in name.enumerated() {
                image.primaryTable[at + 56 + i * 2] = UInt8(truncatingIfNeeded: word)
                image.primaryTable[at + 57 + i * 2] = UInt8(truncatingIfNeeded: word >> 8)
            }
        }
        let tableLength = header.entryCount * 128
        image.backupTable.replaceSubrange(0..<tableLength, with: image.primaryTable.prefix(tableLength))
        let crc = DiskChecksums.crc32(Data(image.primaryTable.prefix(tableLength)))
        for isPrimary in [true, false] {
            var block = isPrimary ? image.primaryHeader : image.backupHeader
            let length = isPrimary ? header.size : secondary.size
            block.put32(crc, at: 88); block.put32(0, at: 16)
            block.put32(DiskChecksums.crc32(Data(block.prefix(length))), at: 16)
            if isPrimary { image.primaryHeader = block } else { image.backupHeader = block }
        }
        image.header = try GPTHeader.parse(image.primaryHeader, sectorSize: sectorSize, totalBlocks: totalBlocks)
        image.secondary = try GPTHeader.parse(image.backupHeader, sectorSize: sectorSize, totalBlocks: totalBlocks)
        _ = try image.partitions(diskName: "disk0")
        return image
    }

    /// Backup first, then primary. Never write the protective MBR.
    public var writeRegions: [(offset: Int64, data: Data)] {
        [(secondary.tableLBA * sectorSize, backupTable), (secondary.current * sectorSize, backupHeader),
         (header.tableLBA * sectorSize, primaryTable), (sectorSize, primaryHeader)]
    }
}
