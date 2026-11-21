import Foundation
import ResizeCore

/// Read-only on-disk APFS snapshot and physical-block tidemark analyzer.
///
/// Mirrors the iOS 12.4 `apfs-945.272.3` kernel's `nx_get_minimal_size`,
/// `fs_snapshot_tidemark`, and `omap_check_range_mappings` directly from the
/// checksummed container checkpoint on disk without modifying storage.
public struct APFSSnapshotReport: Codable, Equatable, Sendable {
    public struct SnapshotDetail: Codable, Equatable, Sendable {
        public var name: String
        public var xid: UInt64
        public var extentrefTreeOID: UInt64
        public var extentrefTreeType: UInt32
        public var sblockOID: UInt64
        public var flags: UInt32
        public var isRootTo: Bool
        public var isRevertTo: Bool
        public var extentMinBlock: UInt64?
        public var extentMaxBlock: UInt64?
        public var treeNodeMaxBlock: UInt64?
        public var treeNodeCount: Int
        /// Matches `fs_snapshot_tidemark`: max(extentMaxBlock, treeNodeMaxBlock).
        public var effectiveTidemarkBlock: UInt64
        public var effectiveTidemarkBytes: Int64
        /// Estimated `nx_get_minimal_size` floor caused by this snapshot alone.
        public var estimatedMinimumBytes: Int64
        public var parseNote: String?
    }

    public struct VolumeDetail: Codable, Equatable, Sendable {
        public var index: Int
        public var fsOID: UInt64
        public var name: String
        public var uuid: UUID
        public var role: UInt16
        public var roleName: String
        public var allocatedBlocks: UInt64
        public var numSnapshots: UInt64
        public var rootToXID: UInt64
        public var revertToXID: UInt64
        public var omapMostRecentSnapXID: UInt64
        public var liveExtentMinBlock: UInt64?
        public var liveExtentMaxBlock: UInt64?
        /// Highest physical block referenced by volume omap entries with xid <= om_most_recent_snap.
        public var snapshotOmapMaxBlock: UInt64?
        /// Highest physical block referenced by volume omap entries with xid > om_most_recent_snap.
        public var liveOmapMaxBlock: UInt64?
        public var snapshots: [SnapshotDetail]
        public var parseNote: String?
    }

    public var containerID: UUID
    public var transactionID: UInt64
    public var blockSize: Int64
    public var blockCount: Int64
    public var maxFileSystems: UInt32
    public var alignmentBlocks: Int64
    public var maxSnapshotTidemarkBlock: UInt64
    public var maxSnapshotTidemarkBytes: Int64
    public var estimatedSnapshotMinimumBytes: Int64?
    public var pinningVolume: String?
    public var pinningSnapshot: String?
    public var volumes: [VolumeDetail]

    public static func capture(partitionBytes: Int64, read: @escaping GPTImage.Reader) throws -> APFSSnapshotReport {
        let prefix = try read(0, 4096)
        guard prefix.count == 4096, prefix[32..<36] == Data("NXSB".utf8) else {
            throw ResizeError("The APFS container superblock is not recognizable.")
        }
        let blockSize = Int64(prefix.le32(36))
        guard [4096, 8192, 16384, 32768, 65536].contains(blockSize), partitionBytes >= blockSize else {
            throw ResizeError("Unsupported APFS block size.")
        }
        let first = blockSize == 4096 ? prefix : try read(0, Int(blockSize))
        guard DiskChecksums.validAPFSObject(first) else {
            throw ResizeError("APFS superblock checksum is invalid.")
        }
        let descriptors = first.le32(104)
        guard descriptors & 0x80000000 == 0, descriptors > 0, descriptors <= 8192,
              first.le64(112) <= UInt64(Int64.max / blockSize) else {
            throw ResizeError("Unsupported or unbounded APFS checkpoint descriptor area.")
        }
        let base = Int64(first.le64(112))
        guard base > 0, base <= partitionBytes / blockSize - Int64(descriptors) else {
            throw ResizeError("APFS checkpoints exceed the partition.")
        }
        let ring = try read(base * blockSize, Int(Int64(descriptors) * blockSize))
        var candidates = [first]
        var maps: [UInt64: [Data]] = [:]
        for offset in stride(from: 0, to: ring.count, by: Int(blockSize)) {
            let object = Data(ring[offset..<(offset + Int(blockSize))])
            guard DiskChecksums.validAPFSObject(object) else { continue }
            if object[32..<36] == Data("NXSB".utf8), object[72..<88] == first[72..<88] {
                candidates.append(object)
            }
            if object.le32(24) & 0xffff == 12 {
                maps[object.le64(16), default: []].append(object)
            }
        }
        guard let nxsb = candidates
            .sorted(by: { $0.le64(16) > $1.le64(16) })
            .first(where: { candidate in
                let count = candidate.le64(40), xid = candidate.le64(16)
                guard candidate.le32(36) == blockSize, count > 0,
                      count <= UInt64(partitionBytes / blockSize),
                      let cpMaps = maps[xid],
                      cpMaps.contains(where: { $0.le32(32) & 1 != 0 }) else { return false }
                return true
            })
        else {
            throw ResizeError("Could not establish a complete, checksummed APFS checkpoint.")
        }

        let blockCount = Int64(nxsb.le64(40))
        let xid = nxsb.le64(16)
        let containerID = bigEndianUUID(nxsb, at: 72)
        let nxOmapOID = nxsb.le64(160)
        let maxFS = min(nxsb.le32(180), 100)
        let alignBlocks = alignmentBlocksFor(totalBlocks: blockCount, blockSize: blockSize)

        let reader = BlockReader(blockSize: blockSize, blockCount: blockCount, partitionBytes: partitionBytes, read: read)
        let containerOmapBlock = try reader.readBlock(nxOmapOID)
        guard containerOmapBlock.le32(24) & 0xffff == 0x000b else {
            throw ResizeError("Container object map header has unexpected type.")
        }
        let containerOmapTreeOID = containerOmapBlock.le64(48)

        var volumes: [VolumeDetail] = []
        var maxTidemark: UInt64 = 0
        var pinVolume: String?
        var pinSnapshot: String?

        for fsIndex in 0..<Int(maxFS) {
            let oidOffset = 184 + fsIndex * 8
            guard oidOffset + 8 <= nxsb.count else { break }
            let fsOID = nxsb.le64(oidOffset)
            if fsOID == 0 { continue }

            guard let fsPaddr = try lookupOmap(reader: reader, treeRootPaddr: containerOmapTreeOID,
                                               oid: fsOID, maxXID: xid) else {
                continue
            }
            let apsb = try reader.readBlock(fsPaddr)
            guard apsb.count >= 976, apsb[32..<36] == Data("APSB".utf8) else { continue }

            let allocBlocks = apsb.le64(88)
            let extentrefTreeType = apsb.le32(120)
            let snapMetaTreeType = apsb.le32(124)
            let volOmapOID = apsb.le64(128)
            let liveExtentrefOID = apsb.le64(144)
            let snapMetaTreeOID = apsb.le64(152)
            let revertToXID = apsb.le64(160)
            let numSnapshots = apsb.le64(216)
            let volUUID = bigEndianUUID(apsb, at: 240)
            let volName = readCString(apsb, offset: 704, maxLength: 256)
            let role = le16(apsb, 964)
            let rootToXID = apsb.le64(968)

            var volOmapTreeOID: UInt64 = 0
            var omMostRecentSnap: UInt64 = 0
            var volParseNote: String?
            if volOmapOID != 0, let volOmap = try? reader.readBlock(volOmapOID),
               volOmap.le32(24) & 0xffff == 0x000b {
                volOmapTreeOID = volOmap.le64(48)
                omMostRecentSnap = volOmap.le64(64)
            }

            let resolveTreePaddr: (UInt64, UInt32) -> UInt64? = { oid, objType in
                if oid == 0 { return nil }
                if (objType & 0x4000_0000) != 0 { return oid }
                guard volOmapTreeOID != 0 else { return nil }
                return try? lookupOmap(reader: reader, treeRootPaddr: volOmapTreeOID, oid: oid, maxXID: xid)
            }

            var liveMin: UInt64?
            var liveMax: UInt64?
            if let livePaddr = resolveTreePaddr(liveExtentrefOID, extentrefTreeType) {
                if let range = try? extentRangeFast(reader: reader, rootPaddr: livePaddr,
                                                    isPhysical: (extentrefTreeType & 0x4000_0000) != 0,
                                                    volOmapTreeOID: volOmapTreeOID, maxXID: xid) {
                    liveMin = range.minBlock
                    liveMax = range.maxBlock
                }
            }

            var snapOmapMax: UInt64?
            var liveOmapMax: UInt64?
            if volOmapTreeOID != 0 && (numSnapshots > 0 || omMostRecentSnap > 0) {
                if let omapScan = try? scanVolumeOmap(reader: reader, treeRootPaddr: volOmapTreeOID,
                                                      mostRecentSnapXID: omMostRecentSnap) {
                    snapOmapMax = omapScan.snapMaxBlock
                    liveOmapMax = omapScan.liveMaxBlock
                } else {
                    volParseNote = "Could not scan volume omap tree."
                }
            }

            var snapDetails: [SnapshotDetail] = []
            if numSnapshots > 0, let snapTreePaddr = resolveTreePaddr(snapMetaTreeOID, snapMetaTreeType) {
                let rawSnaps = (try? collectSnapshotMetadata(reader: reader, rootPaddr: snapTreePaddr,
                                                             isPhysical: (snapMetaTreeType & 0x4000_0000) != 0,
                                                             volOmapTreeOID: volOmapTreeOID, maxXID: xid)) ?? []
                for raw in rawSnaps.sorted(by: { $0.xid < $1.xid }) {
                    let extType = raw.extentrefTreeType != 0 ? raw.extentrefTreeType : extentrefTreeType
                    var extMin: UInt64?
                    var extMax: UInt64?
                    var nodeMax: UInt64?
                    var nodeCount = 0
                    var snapNote: String?
                    if raw.extentrefTreeOID == 0 {
                        snapNote = "dataless snapshot (extentref_tree_oid == 0)"
                    } else if let extPaddr = resolveTreePaddr(raw.extentrefTreeOID, extType) {
                        if let stats = try? analyzeExtentrefTree(reader: reader, rootPaddr: extPaddr,
                                                                 isPhysical: (extType & 0x4000_0000) != 0,
                                                                 volOmapTreeOID: volOmapTreeOID, maxXID: xid) {
                            extMin = stats.minBlock
                            extMax = stats.maxBlock
                            nodeMax = stats.maxNodeBlock
                            nodeCount = stats.nodeCount
                        } else {
                            snapNote = "failed to walk snapshot extentref_tree"
                        }
                    } else {
                        snapNote = "failed to resolve snapshot extentref_tree OID"
                    }
                    let effective = max(extMax ?? 0, nodeMax ?? 0)
                    let effectiveBytes = Int64(effective) * blockSize
                    let estMin = estimateMinimumBytes(tidemarkBlocks: Int64(effective),
                                                      totalBlocks: blockCount,
                                                      blockSize: blockSize,
                                                      maxFileSystems: maxFS)
                    if effective > maxTidemark {
                        maxTidemark = effective
                        pinVolume = volName
                        pinSnapshot = raw.name
                    }
                    let isRootTo = rootToXID != 0 && rootToXID == raw.xid
                    let isRevertTo = revertToXID != 0 && revertToXID == raw.xid
                    let detail = SnapshotDetail(
                        name: raw.name,
                        xid: raw.xid,
                        extentrefTreeOID: raw.extentrefTreeOID,
                        extentrefTreeType: extType,
                        sblockOID: raw.sblockOID,
                        flags: raw.flags,
                        isRootTo: isRootTo,
                        isRevertTo: isRevertTo,
                        extentMinBlock: extMin,
                        extentMaxBlock: extMax,
                        treeNodeMaxBlock: nodeMax,
                        treeNodeCount: nodeCount,
                        effectiveTidemarkBlock: effective,
                        effectiveTidemarkBytes: effectiveBytes,
                        estimatedMinimumBytes: estMin,
                        parseNote: snapNote
                    )
                    snapDetails.append(detail)
                }
            }

            volumes.append(VolumeDetail(
                index: fsIndex,
                fsOID: fsOID,
                name: volName,
                uuid: volUUID,
                role: role,
                roleName: describeRole(role),
                allocatedBlocks: allocBlocks,
                numSnapshots: numSnapshots,
                rootToXID: rootToXID,
                revertToXID: revertToXID,
                omapMostRecentSnapXID: omMostRecentSnap,
                liveExtentMinBlock: liveMin,
                liveExtentMaxBlock: liveMax,
                snapshotOmapMaxBlock: snapOmapMax,
                liveOmapMaxBlock: liveOmapMax,
                snapshots: snapDetails,
                parseNote: volParseNote
            ))
        }

        let estimatedMin: Int64? = maxTidemark > 0
            ? estimateMinimumBytes(tidemarkBlocks: Int64(maxTidemark),
                                   totalBlocks: blockCount,
                                   blockSize: blockSize,
                                   maxFileSystems: maxFS)
            : nil

        return APFSSnapshotReport(
            containerID: containerID,
            transactionID: xid,
            blockSize: blockSize,
            blockCount: blockCount,
            maxFileSystems: maxFS,
            alignmentBlocks: alignBlocks,
            maxSnapshotTidemarkBlock: maxTidemark,
            maxSnapshotTidemarkBytes: Int64(maxTidemark) * blockSize,
            estimatedSnapshotMinimumBytes: estimatedMin,
            pinningVolume: pinVolume,
            pinningSnapshot: pinSnapshot,
            volumes: volumes
        )
    }

    /// Exact port of iOS 12.4 `nx_calculate_metadata_params` + `nx_get_minimal_size` rounding.
    public static func estimateMinimumBytes(tidemarkBlocks: Int64, totalBlocks: Int64,
                                            blockSize: Int64, maxFileSystems: UInt32) -> Int64 {
        guard tidemarkBlocks > 0, totalBlocks > 0, blockSize >= 4096 else { return 0 }
        let bs = UInt64(blockSize)
        let p2 = UInt64(tidemarkBlocks)
        let totalBytes = UInt64(totalBlocks) * bs
        var defaultMaxFS = (totalBytes >> 29) + ((totalBytes & 0x1fff_ffff) != 0 ? 1 : 0)
        if defaultMaxFS > 100 { defaultMaxFS = 100 }
        let p4Arg: UInt64 = UInt64(maxFileSystems) != defaultMaxFS ? UInt64(maxFileSystems) : 0

        let bitsPerBlock = bs * 8
        let u12 = bs - 0x28
        let u14 = u12 >> 5
        let u15 = u12 >> 3
        let u4 = (bitsPerBlock - 1 + p2) / bitsPerBlock
        let u5 = (u14 - 1 + u4) / u14
        let u6 = (u15 - 1 + u5) / u15
        let u13 = u6 == 1 ? 0 : u6
        let ipBlocks = (u4 + u5 + u13) * 3
        let ipBMBlocks = ((bs - 1) + (((ipBlocks + 0x3f) >> 3) & ~UInt64(7))) / bs
        let ipBMRing = ipBMBlocks << 4
        let l17 = u13 != 0 ? u13 : u5
        var smSize = ((ipBMBlocks * 2 + 6) & ~UInt64(7)) + ipBMBlocks * 8 + l17 * 8
            + ((ipBMRing * 2 + 6) & ~UInt64(7)) + 0x9d8
        smSize = ((smSize + bs - 1) / bs) * bs

        let u14b = ((bs - 0x60) - (((((bs - 0x60) >> 2) & 0x3fff) / 7) * 4 + 0x1c & 0x7fe0)) / 0x30
        let u15b = 0x20_0000 / bs
        let shift: UInt64 = p2 < 0x4_0000 ? 6 : (p2 > 0xf_ffff ? 4 : 5)
        let addMask: UInt64 = p2 < 0x4_0000 ? 0x3f : (p2 > 0xf_ffff ? 0xf : 0x1f)
        var u4b = min((u14b - 1 + ((addMask + p2) >> shift)) / u14b, u15b)
        if u4b == 2 { u4b = 3 }
        let u13c: UInt64 = (p2 >> 20) != 0 ? ((ipBlocks + 0xf) >> 4)
            : ((p2 >> 18) != 0 ? ((ipBlocks + 0x1f) >> 5) : ((ipBlocks + 0x3f) >> 6))
        var u14c = min((u14b - 1 + u13c) / u14b, u15b)
        if u14c == 2 { u14c = 3 }
        let u15c = smSize / bs
        let l16c = u15c <= 1 ? 0 : u15c - 1
        let u11c = min(u4b, 8)
        var p4 = p4Arg
        if p4 == 0 {
            let newBytes = p2 * bs
            p4 = (newBytes >> 29) + ((newBytes & 0x1fff_ffff) != 0 ? 1 : 0)
            if p4 > 100 { p4 = 100 }
        }
        let u11d = 2 + u4b + u15c + u14c + l16c + u11c * p4 * 8
        let u15d = (u12 & 0xffff) / 0x28
        let xpDesc = (((u11d + u15d - 1) / u15d) * 4) + 4
        let xpData = u11d * 4
        let twoMeta = (ipBlocks + ipBMRing + xpDesc + xpData) * 2

        let align = UInt64(alignmentBlocksFor(totalBlocks: totalBlocks, blockSize: blockSize))
        let raw = p2 + twoMeta
        let aligned = min(UInt64(totalBlocks), (raw + align - 1) & ~(align - 1))
        return Int64(aligned) * blockSize
    }

    public static func alignmentBlocksFor(totalBlocks: Int64, blockSize: Int64) -> Int64 {
        guard totalBlocks > 0, blockSize > 0 else { return 1 }
        let totalBytes = UInt64(totalBlocks) * UInt64(blockSize)
        var zoneBytes = totalBytes >> 14
        if (totalBytes >> 39) != 0 { zoneBytes = 0x200_0000 }
        let clamped = max(UInt64(0x10_0000), zoneBytes)
        let blocks = clamped / UInt64(blockSize)
        guard blocks > 0 else { return 1 }
        var p: UInt64 = 1
        while p < blocks && p < (1 << 30) { p <<= 1 }
        return Int64(p)
    }

    // MARK: - Low-level APFS B-tree readers

    private struct BlockReader {
        let blockSize: Int64
        let blockCount: Int64
        let partitionBytes: Int64
        let read: GPTImage.Reader

        func readBlock(_ paddr: UInt64) throws -> Data {
            guard paddr < UInt64(blockCount), paddr <= UInt64(Int64.max / blockSize) else {
                throw ResizeError("APFS block address \(paddr) is out of container bounds.")
            }
            let offset = Int64(paddr) * blockSize
            guard offset <= partitionBytes - blockSize else {
                throw ResizeError("APFS block \(paddr) exceeds partition length.")
            }
            let data = try read(offset, Int(blockSize))
            guard data.count == Int(blockSize), DiskChecksums.validAPFSObject(data) else {
                throw ResizeError("APFS block \(paddr) failed Fletcher-64 checksum validation.")
            }
            return data
        }
    }

    private struct BTreeEntry {
        let key: Data
        let val: Data
    }

    private struct ParsedNode {
        let flags: UInt16
        let level: UInt16
        let keySize: Int
        let valSize: Int
        let entries: [BTreeEntry]
        var isRoot: Bool { (flags & 0x0001) != 0 }
        var isLeaf: Bool { (flags & 0x0002) != 0 }
        var isFixed: Bool { (flags & 0x0004) != 0 }
    }

    private static func parseBTreeNode(_ data: Data, fixedKeySize: Int = 0, fixedValSize: Int = 0) throws -> ParsedNode {
        guard data.count >= 56 + 40 else { throw ResizeError("APFS B-tree node too small.") }
        let flags = le16(data, 32)
        let level = le16(data, 34)
        let nkeys = Int(data.le32(36))
        let tocOff = Int(le16(data, 40))
        let tocLen = Int(le16(data, 42))
        let isRoot = (flags & 0x0001) != 0
        let isFixed = (flags & 0x0004) != 0
        let isLeaf = (flags & 0x0002) != 0

        var kSize = fixedKeySize
        var vSize = fixedValSize
        if isRoot && isFixed {
            let infoBase = data.count - 40
            kSize = Int(data.le32(infoBase + 8))
            vSize = Int(data.le32(infoBase + 12))
        }
        let effectiveValSize = isLeaf ? vSize : 8

        let tocBase = 56 + tocOff
        let keyBase = tocBase + tocLen
        let valEnd = isRoot ? (data.count - 40) : data.count
        guard tocBase <= data.count, keyBase <= valEnd else {
            throw ResizeError("APFS B-tree node table-of-contents bounds invalid.")
        }

        var entries: [BTreeEntry] = []
        entries.reserveCapacity(min(nkeys, 1024))
        for i in 0..<nkeys {
            let kOff: Int, kLen: Int, vOff: Int, vLen: Int
            if isFixed {
                let entryAt = tocBase + i * 4
                guard entryAt + 4 <= keyBase else { break }
                kOff = Int(le16(data, entryAt))
                vOff = Int(le16(data, entryAt + 2))
                kLen = kSize
                vLen = effectiveValSize
            } else {
                let entryAt = tocBase + i * 8
                guard entryAt + 8 <= keyBase else { break }
                kOff = Int(le16(data, entryAt))
                kLen = Int(le16(data, entryAt + 2))
                vOff = Int(le16(data, entryAt + 4))
                vLen = Int(le16(data, entryAt + 6))
            }
            let kStart = keyBase + kOff
            let vStart = valEnd - vOff
            guard kStart >= keyBase, kStart + kLen <= valEnd,
                  vOff > 0, vStart >= keyBase, vStart + vLen <= valEnd else {
                continue
            }
            entries.append(BTreeEntry(
                key: Data(data[kStart..<(kStart + kLen)]),
                val: Data(data[vStart..<(vStart + vLen)])
            ))
        }
        return ParsedNode(flags: flags, level: level, keySize: kSize, valSize: vSize, entries: entries)
    }

    private static func lookupOmap(reader: BlockReader, treeRootPaddr: UInt64,
                                   oid: UInt64, maxXID: UInt64) throws -> UInt64? {
        var currentPaddr = treeRootPaddr
        var fixedK = 16, fixedV = 16
        for _ in 0..<16 {
            let block = try reader.readBlock(currentPaddr)
            let node = try parseBTreeNode(block, fixedKeySize: fixedK, fixedValSize: fixedV)
            if node.isRoot && node.isFixed {
                fixedK = node.keySize
                fixedV = node.valSize
            }
            if node.isLeaf {
                var bestPaddr: UInt64?
                var bestXID: UInt64 = 0
                for entry in node.entries where entry.key.count >= 16 && entry.val.count >= 16 {
                    let kOID = entry.key.le64(0)
                    let kXID = entry.key.le64(8)
                    if kOID == oid && kXID <= maxXID && (bestPaddr == nil || kXID >= bestXID) {
                        let flags = entry.val.le32(0)
                        if (flags & 0x0000_0001) == 0 { // not OMAP_VAL_DELETED
                            bestXID = kXID
                            bestPaddr = entry.val.le64(8)
                        } else {
                            bestXID = kXID
                            bestPaddr = nil
                        }
                    }
                }
                return bestPaddr
            }
            var chosen: UInt64?
            for entry in node.entries where entry.key.count >= 16 && entry.val.count >= 8 {
                let kOID = entry.key.le64(0)
                let kXID = entry.key.le64(8)
                if kOID < oid || (kOID == oid && kXID <= maxXID) {
                    chosen = entry.val.le64(0)
                } else {
                    break
                }
            }
            guard let next = chosen else { return nil }
            currentPaddr = next
        }
        return nil
    }

    private struct RawSnapshotMeta {
        var xid: UInt64
        var extentrefTreeOID: UInt64
        var sblockOID: UInt64
        var extentrefTreeType: UInt32
        var flags: UInt32
        var name: String
    }

    private static func collectSnapshotMetadata(reader: BlockReader, rootPaddr: UInt64,
                                                isPhysical: Bool, volOmapTreeOID: UInt64,
                                                maxXID: UInt64) throws -> [RawSnapshotMeta] {
        var result: [RawSnapshotMeta] = []
        var stack: [UInt64] = [rootPaddr]
        var visited = Set<UInt64>()
        var fixedK = 0, fixedV = 0
        while let paddr = stack.popLast(), visited.count < 4096 {
            guard visited.insert(paddr).inserted else { continue }
            let block = try reader.readBlock(paddr)
            let node = try parseBTreeNode(block, fixedKeySize: fixedK, fixedValSize: fixedV)
            if node.isRoot && node.isFixed { fixedK = node.keySize; fixedV = node.valSize }
            if node.isLeaf {
                for entry in node.entries where entry.key.count >= 8 && entry.val.count >= 50 {
                    let rawKey = entry.key.le64(0)
                    let keyType = rawKey >> 60
                    guard keyType == 1 else { continue } // APFS_TYPE_SNAP_METADATA
                    let snapXID = rawKey & 0x0fff_ffff_ffff_ffff
                    let extOID = entry.val.le64(0)
                    let sbOID = entry.val.le64(8)
                    let extType = entry.val.le32(40)
                    let flags = entry.val.le32(44)
                    let nameLen = Int(le16(entry.val, 48))
                    let avail = min(nameLen, max(0, entry.val.count - 50))
                    let name = readCString(entry.val, offset: 50, maxLength: avail)
                    result.append(RawSnapshotMeta(
                        xid: snapXID,
                        extentrefTreeOID: extOID,
                        sblockOID: sbOID,
                        extentrefTreeType: extType,
                        flags: flags,
                        name: name
                    ))
                }
            } else {
                for entry in node.entries.reversed() where entry.val.count >= 8 {
                    let childOID = entry.val.le64(0)
                    let childPaddr: UInt64? = isPhysical
                        ? childOID
                        : (try? lookupOmap(reader: reader, treeRootPaddr: volOmapTreeOID,
                                           oid: childOID, maxXID: maxXID))
                    if let childPaddr { stack.append(childPaddr) }
                }
            }
        }
        return result
    }

    private static func extentRangeFast(reader: BlockReader, rootPaddr: UInt64,
                                        isPhysical: Bool, volOmapTreeOID: UInt64,
                                        maxXID: UInt64) throws -> (minBlock: UInt64?, maxBlock: UInt64?) {
        func descend(rightmost: Bool) throws -> BTreeEntry? {
            var paddr = rootPaddr
            var fixedK = 0, fixedV = 0
            for _ in 0..<16 {
                let block = try reader.readBlock(paddr)
                let node = try parseBTreeNode(block, fixedKeySize: fixedK, fixedValSize: fixedV)
                if node.isRoot && node.isFixed { fixedK = node.keySize; fixedV = node.valSize }
                if node.isLeaf {
                    return rightmost ? node.entries.last : node.entries.first
                }
                guard let chosen = rightmost ? node.entries.last : node.entries.first,
                      chosen.val.count >= 8 else { return nil }
                let childOID = chosen.val.le64(0)
                if isPhysical {
                    paddr = childOID
                } else {
                    guard let resolved = try lookupOmap(reader: reader, treeRootPaddr: volOmapTreeOID,
                                                        oid: childOID, maxXID: maxXID) else { return nil }
                    paddr = resolved
                }
            }
            return nil
        }
        var minBlk: UInt64?
        var maxBlk: UInt64?
        if let first = try descend(rightmost: false), first.key.count >= 8 {
            minBlk = first.key.le64(0) & 0x0fff_ffff_ffff_ffff
        }
        if let last = try descend(rightmost: true), last.key.count >= 8, last.val.count >= 8 {
            let start = last.key.le64(0) & 0x0fff_ffff_ffff_ffff
            let len = last.val.le64(0) & 0x0fff_ffff_ffff_ffff
            if len > 0 { maxBlk = start + len - 1 }
        }
        return (minBlk, maxBlk)
    }

    private struct ExtentrefStats {
        var minBlock: UInt64?
        var maxBlock: UInt64?
        var maxNodeBlock: UInt64?
        var nodeCount: Int
    }

    private static func analyzeExtentrefTree(reader: BlockReader, rootPaddr: UInt64,
                                             isPhysical: Bool, volOmapTreeOID: UInt64,
                                             maxXID: UInt64) throws -> ExtentrefStats {
        let fast = try extentRangeFast(reader: reader, rootPaddr: rootPaddr,
                                       isPhysical: isPhysical, volOmapTreeOID: volOmapTreeOID,
                                       maxXID: maxXID)
        var maxNode: UInt64 = rootPaddr
        var visited = Set<UInt64>()
        var stack: [UInt64] = [rootPaddr]
        var fixedK = 0, fixedV = 0
        while let paddr = stack.popLast(), visited.count < 65536 {
            guard visited.insert(paddr).inserted else { continue }
            if paddr > maxNode { maxNode = paddr }
            let block = try reader.readBlock(paddr)
            let node = try parseBTreeNode(block, fixedKeySize: fixedK, fixedValSize: fixedV)
            if node.isRoot && node.isFixed { fixedK = node.keySize; fixedV = node.valSize }
            if !node.isLeaf {
                for entry in node.entries where entry.val.count >= 8 {
                    let childOID = entry.val.le64(0)
                    let childPaddr: UInt64? = isPhysical
                        ? childOID
                        : (try? lookupOmap(reader: reader, treeRootPaddr: volOmapTreeOID,
                                           oid: childOID, maxXID: maxXID))
                    if let childPaddr { stack.append(childPaddr) }
                }
            }
        }
        return ExtentrefStats(minBlock: fast.minBlock, maxBlock: fast.maxBlock,
                              maxNodeBlock: maxNode, nodeCount: visited.count)
    }

    private static func scanVolumeOmap(reader: BlockReader, treeRootPaddr: UInt64,
                                       mostRecentSnapXID: UInt64) throws -> (snapMaxBlock: UInt64?, liveMaxBlock: UInt64?) {
        let bs = UInt64(reader.blockSize)
        var snapMax: UInt64?
        var liveMax: UInt64?
        var visited = Set<UInt64>()
        var stack: [UInt64] = [treeRootPaddr]
        var fixedK = 16, fixedV = 16
        while let paddr = stack.popLast(), visited.count < 131_072 {
            guard visited.insert(paddr).inserted else { continue }
            let block = try reader.readBlock(paddr)
            let node = try parseBTreeNode(block, fixedKeySize: fixedK, fixedValSize: fixedV)
            if node.isRoot && node.isFixed {
                fixedK = node.keySize
                fixedV = node.valSize
            }
            if node.isLeaf {
                for entry in node.entries where entry.key.count >= 16 && entry.val.count >= 16 {
                    let kXID = entry.key.le64(8)
                    let flags = entry.val.le32(0)
                    if (flags & 0x0000_0001) != 0 { continue } // deleted
                    let size = UInt64(entry.val.le32(4))
                    let objPaddr = entry.val.le64(8)
                    let blocks = max(1, (size + bs - 1) / bs)
                    let endBlock = objPaddr + blocks - 1
                    if kXID <= mostRecentSnapXID {
                        if snapMax == nil || endBlock > snapMax! { snapMax = endBlock }
                    } else {
                        if liveMax == nil || endBlock > liveMax! { liveMax = endBlock }
                    }
                }
            } else {
                for entry in node.entries where entry.val.count >= 8 {
                    stack.append(entry.val.le64(0))
                }
            }
        }
        return (snapMax, liveMax)
    }

    // MARK: - Helpers

    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func bigEndianUUID(_ data: Data, at offset: Int) -> UUID {
        let b = Array(data[(data.startIndex + offset)..<(data.startIndex + offset + 16)])
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }

    private static func readCString(_ data: Data, offset: Int, maxLength: Int) -> String {
        guard offset >= 0, offset < data.count, maxLength > 0 else { return "" }
        let end = min(data.count, offset + maxLength)
        var bytes: [UInt8] = []
        for idx in offset..<end {
            let b = data[data.startIndex + idx]
            if b == 0 { break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func describeRole(_ role: UInt16) -> String {
        switch role {
        case 0x0000: return "None"
        case 0x0001: return "System"
        case 0x0002: return "User"
        case 0x0004: return "Recovery"
        case 0x0008: return "VM"
        case 0x0010: return "Preboot"
        case 0x0020: return "Installer"
        case 0x0040: return "Data"
        case 0x0080: return "Baseband"
        default: return String(format: "0x%04x", role)
        }
    }
}
