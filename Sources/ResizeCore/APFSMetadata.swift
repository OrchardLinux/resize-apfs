import Foundation

public struct APFSMetadata: Codable, Equatable, Sendable {
    public let containerID: UUID
    public let transactionID: UInt64
    public let blockSize: Int64
    public let blockCount: Int64
    public let allocatedBytes: Int64
    public var capacityBytes: Int64 { blockSize * blockCount }

    /// Reads checksummed container-level metadata only; does not mount, unlock,
    /// repair or traverse user files. Unknown layouts are refused.
    public static func capture(partitionBytes: Int64, read: GPTImage.Reader) throws -> APFSMetadata {
        let prefix = try read(0, 4096)
        guard prefix.count == 4096, prefix[32..<36] == Data("NXSB".utf8) else {
            throw ResizeError("The APFS container superblock is not recognizable.")
        }
        let block = Int64(prefix.le32(36))
        guard [4096, 8192, 16384, 32768, 65536].contains(block), partitionBytes >= block else {
            throw ResizeError("Unsupported APFS block size.")
        }
        let first = block == 4096 ? prefix : try read(0, Int(block))
        guard DiskChecksums.validAPFSObject(first) else { throw ResizeError("APFS superblock checksum is invalid.") }
        let uuidBytes = Array(first[72..<88])
        let id = UUID(uuid: (uuidBytes[0],uuidBytes[1],uuidBytes[2],uuidBytes[3],uuidBytes[4],uuidBytes[5],uuidBytes[6],uuidBytes[7],uuidBytes[8],uuidBytes[9],uuidBytes[10],uuidBytes[11],uuidBytes[12],uuidBytes[13],uuidBytes[14],uuidBytes[15]))
        let descriptors = first.le32(104)
        guard descriptors & 0x80000000 == 0, descriptors > 0, descriptors <= 8192,
              first.le64(112) <= UInt64(Int64.max / block) else {
            throw ResizeError("Unsupported or unbounded APFS checkpoint descriptor area.")
        }
        let base = Int64(first.le64(112))
        guard base > 0, base <= partitionBytes / block - Int64(descriptors) else { throw ResizeError("APFS checkpoints exceed the partition.") }
        let ring = try read(base * block, Int(Int64(descriptors) * block))
        var candidates = [first]
        var maps: [UInt64: [Data]] = [:]
        for offset in stride(from: 0, to: ring.count, by: Int(block)) {
            let object = Data(ring[offset..<(offset + Int(block))])
            guard DiskChecksums.validAPFSObject(object) else { continue }
            if object[32..<36] == Data("NXSB".utf8), object[72..<88] == first[72..<88] { candidates.append(object) }
            if object.le32(24) & 0xffff == 12 { maps[object.le64(16), default: []].append(object) }
        }
        for candidate in candidates.sorted(by: { $0.le64(16) > $1.le64(16) }) {
            let count = candidate.le64(40), xid = candidate.le64(16), spaceman = candidate.le64(152)
            guard candidate.le32(36) == block, count > 0,
                  count <= UInt64(partitionBytes / block), spaceman != 0,
                  let checkpointMaps = maps[xid], checkpointMaps.contains(where: { $0.le32(32) & 1 != 0 }) else { continue }
            var addresses = Set<UInt64>()
            for map in checkpointMaps {
                let entries = Int(map.le32(36))
                guard entries <= (map.count - 40) / 40 else { throw ResizeError("Invalid APFS checkpoint map.") }
                for i in 0..<entries {
                    let at = 40 + i * 40
                    if map.le64(at + 24) == spaceman, map.le32(at) & 0xffff == 5,
                       map.le32(at + 8) == block { addresses.insert(map.le64(at + 32)) }
                }
            }
            guard addresses.count == 1, let address = addresses.first, address < count else { continue }
            let sm = try read(Int64(address) * block, Int(block))
            guard DiskChecksums.validAPFSObject(sm), sm.le64(8) == spaceman, sm.le64(16) == xid,
                  sm.le32(24) & 0xffff == 5, sm.le32(32) == block,
                  sm.le64(48) == count, sm.le64(72) <= count else { continue }
            return APFSMetadata(containerID: id, transactionID: xid, blockSize: block, blockCount: Int64(count),
                                allocatedBytes: Int64(count - sm.le64(72)) * block)
        }
        throw ResizeError("Could not establish a complete, checksummed APFS checkpoint. No changes are permitted.")
    }
}
