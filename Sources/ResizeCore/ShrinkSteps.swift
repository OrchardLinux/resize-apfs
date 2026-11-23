import Foundation

/// How much of each APFS space-manager chunk is allocated, as of the newest
/// on-disk checkpoint. Read-only and approximate: the mounted system may have
/// written since, so it only sizes shrink steps and never decides safety.
public struct APFSSpaceMap: Equatable, Sendable {
    public struct Chunk: Equatable, Sendable {
        public var firstBlock: Int64
        public var blockCount: Int64
        public var freeBlocks: Int64
        public var allocatedBlocks: Int64 { blockCount - freeBlocks }
        public init(firstBlock: Int64, blockCount: Int64, freeBlocks: Int64) {
            self.firstBlock = firstBlock; self.blockCount = blockCount; self.freeBlocks = freeBlocks
        }
    }
    public let blockSize: Int64
    public let blockCount: Int64
    public let chunks: [Chunk]
    public var containerBytes: Int64 { blockSize * blockCount }

    /// Refuses anything that does not cover the container exactly once, in order.
    public init(blockSize: Int64, blockCount: Int64, chunks: [Chunk]) throws {
        guard blockSize >= 4096, blockSize.nonzeroBitCount == 1, blockCount > 0, !chunks.isEmpty else {
            throw ResizeError("Empty or invalid APFS space map.")
        }
        var next: Int64 = 0
        for chunk in chunks {
            guard chunk.firstBlock == next, chunk.blockCount > 0, chunk.freeBlocks >= 0,
                  chunk.freeBlocks <= chunk.blockCount else { throw ResizeError("APFS space-map chunks are inconsistent.") }
            next += chunk.blockCount
        }
        guard next == blockCount else { throw ResizeError("APFS space-map chunks do not cover the container.") }
        self.blockSize = blockSize; self.blockCount = blockCount; self.chunks = chunks
    }

    /// Evenly spread allocation, for the mock service, which has no disk.
    public static func uniform(containerBytes: Int64, allocatedBytes: Int64, blockSize: Int64 = 4096) -> APFSSpaceMap? {
        let blocks = containerBytes / blockSize, perChunk = blockSize * 8
        guard blocks > 0 else { return nil }
        let density = Double(max(0, min(allocatedBytes, containerBytes))) / Double(containerBytes)
        let chunks = stride(from: Int64(0), to: blocks, by: Int(perChunk)).map { first -> Chunk in
            let count = min(perChunk, blocks - first)
            return Chunk(firstBlock: first, blockCount: count, freeBlocks: count - Int64((Double(count) * density).rounded(.up)))
        }
        return try? APFSSpaceMap(blockSize: blockSize, blockCount: blocks, chunks: chunks)
    }

    /// An upper bound of the allocated bytes in [lower, upper): a chunk only
    /// partly inside the range counts as if all its data were in that part.
    public func allocatedBytes(from lower: Int64, to upper: Int64) -> Int64 {
        guard upper > lower else { return 0 }
        var total: Int64 = 0
        var index = chunkIndex(containing: max(0, lower) / blockSize)
        while index < chunks.count {
            let chunk = chunks[index]
            let low = max(chunk.firstBlock * blockSize, lower), high = min((chunk.firstBlock + chunk.blockCount) * blockSize, upper)
            if high <= low { break }
            total += min(chunk.allocatedBlocks * blockSize, high - low)
            index += 1
        }
        return total
    }

    /// The lowest boundary at or above `floor` such that [boundary, upper)
    /// holds at most `budget` allocated bytes by the bound above.
    func lowestBoundary(above floor: Int64, below upper: Int64, budget: Int64) -> Int64 {
        var used: Int64 = 0, boundary = upper
        var index = chunkIndex(containing: (upper - 1) / blockSize)
        while index >= 0 {
            let chunk = chunks[index]
            let low = max(chunk.firstBlock * blockSize, floor), high = min((chunk.firstBlock + chunk.blockCount) * blockSize, upper)
            if high <= low { break }
            let allocated = min(chunk.allocatedBlocks * blockSize, high - low)
            guard used + allocated <= budget else {
                // Inside this chunk: any slice of `room` bytes holds at most `room`.
                return high - (budget - used)
            }
            used += allocated; boundary = low
            index -= 1
        }
        return boundary
    }

    private func chunkIndex(containing block: Int64) -> Int {
        var low = 0, high = chunks.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chunks[middle].firstBlock <= block { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Reads the space manager's chunk-info blocks from the newest complete
    /// checkpoint. Every block must be checksummed and consistent with the
    /// space manager's own counts, or the map is refused.
    public static func capture(partitionBytes: Int64, read: GPTImage.Reader) throws -> APFSSpaceMap {
        let (metadata, sm) = try APFSMetadata.checkpoint(partitionBytes: partitionBytes, read: read)
        let block = metadata.blockSize, blocks = metadata.blockCount, xid = metadata.transactionID
        let perChunk = Int64(sm.le32(36)), chunkCount = sm.le64(56)
        let cibCount = Int(sm.le32(64)), cabCount = Int(sm.le32(68)), freeCount = sm.le64(72), addressOffset = Int(sm.le32(80))
        guard perChunk > 0, perChunk <= block * 8, chunkCount == UInt64((blocks + perChunk - 1) / perChunk),
              cibCount > 0, cibCount <= 1 << 20, cabCount <= 1 << 16 else {
            throw ResizeError("The APFS space manager's chunk counts are not supported.")
        }
        func object(_ address: UInt64, type: UInt32) throws -> Data {
            guard address > 0, address < UInt64(blocks), Int64(address) <= partitionBytes / block - 1 else {
                throw ResizeError("An APFS space-manager block lies outside the container.")
            }
            let data = try read(Int64(address) * block, Int(block))
            guard data.count == Int(block), DiskChecksums.validAPFSObject(data), data.le32(24) & 0xffff == type,
                  data.le64(16) <= xid else { throw ResizeError("An APFS space-manager block is invalid.") }
            return data
        }
        func addresses(in data: Data, at offset: Int, count: Int) throws -> [UInt64] {
            guard offset >= 0, count >= 0, offset + count * 8 <= data.count else {
                throw ResizeError("An APFS space-manager address list exceeds its block.")
            }
            return (0..<count).map { data.le64(offset + $0 * 8) }
        }
        var cibAddresses: [UInt64] = []
        if cabCount == 0 {
            guard addressOffset >= 48 else { throw ResizeError("Invalid APFS space-manager address list.") }
            cibAddresses = try addresses(in: sm, at: addressOffset, count: cibCount)
        } else {
            guard addressOffset >= 48 else { throw ResizeError("Invalid APFS space-manager address list.") }
            for (index, address) in try addresses(in: sm, at: addressOffset, count: cabCount).enumerated() {
                let cab = try object(address, type: 0x8)
                guard Int(cab.le32(32)) == index else { throw ResizeError("APFS chunk-address blocks are out of order.") }
                cibAddresses += try addresses(in: cab, at: 40, count: Int(cab.le32(36)))
            }
            guard cibAddresses.count == cibCount else { throw ResizeError("APFS chunk-info blocks are missing.") }
        }
        var chunks: [Chunk] = []
        var free: UInt64 = 0
        chunks.reserveCapacity(Int(chunkCount))
        for (index, address) in cibAddresses.enumerated() {
            let cib = try object(address, type: 0x7)
            let entries = Int(cib.le32(36))
            guard Int(cib.le32(32)) == index, entries > 0, entries <= (cib.count - 40) / 32 else {
                throw ResizeError("An APFS chunk-info block is inconsistent.")
            }
            for entry in 0..<entries {
                let at = 40 + entry * 32
                let first = Int64(chunks.count) * perChunk
                let count = Int64(cib.le32(at + 16) & 0x000f_ffff), freeBlocks = Int64(cib.le32(at + 20) & 0x000f_ffff)
                guard cib.le64(at) <= xid, cib.le64(at + 8) == UInt64(first), count == min(perChunk, blocks - first) else {
                    throw ResizeError("An APFS chunk-info entry is inconsistent.")
                }
                chunks.append(Chunk(firstBlock: first, blockCount: count, freeBlocks: freeBlocks))
                free += UInt64(max(0, freeBlocks))
            }
        }
        guard chunks.count == Int(chunkCount), free == freeCount else {
            throw ResizeError("APFS chunk-info totals disagree with the space manager.")
        }
        return try APFSSpaceMap(blockSize: block, blockCount: blocks, chunks: chunks)
    }
}

/// The shrink step now running, as the operation journal and the app see it.
public struct APFSStepProgress: Codable, Equatable, Sendable {
    /// 1-based number of the step running (or the last one run).
    public var number: Int
    /// `number` plus the steps still estimated after it; it can change as the
    /// data and the measured speed change.
    public var plannedCount: Int
    public var fromBytes: Int64
    public var targetBytes: Int64
    /// Allocated data this step may move by the space map's bound, or nil
    /// for a fixed-size step (no usable space map).
    public var dataBudgetBytes: Int64?
    /// How long the previous step's APFS resize call took.
    public var previousCallSeconds: Double?
    public init(number: Int, plannedCount: Int, fromBytes: Int64, targetBytes: Int64,
                dataBudgetBytes: Int64?, previousCallSeconds: Double?) {
        self.number = number; self.plannedCount = plannedCount; self.fromBytes = fromBytes
        self.targetBytes = targetBytes; self.dataBudgetBytes = dataBudgetBytes; self.previousCallSeconds = previousCallSeconds
    }
    public var label: String { "Step \(number) of \(max(number, plannedCount))" }
}

/// Splits one large APFS shrink into calls that each relocate a bounded amount
/// of data. APFS holds the container while it moves every allocated block past
/// the new end, so the pause grows with the data moved and the storage speed,
/// not with the size removed. Smaller calls keep each pause short.
public enum ShrinkSteps {
    public static let startingBudget: Int64 = 2 << 30
    public static let minimumBudget: Int64 = 256 << 20
    /// Container bytes per step when the space map cannot be used, at the
    /// starting budget; scaled down with the budget when calls are slow.
    public static let fallbackStepBytes: Int64 = 8 << 30
    public static let slowCallSeconds: Double = 30
    public static let fastCallSeconds: Double = 10
    /// Intermediate targets are whole MiB from the container start.
    public static let alignment: Int64 = 1 << 20
    /// A short rest between calls, so writes iOS queued during one call can
    /// drain before APFS holds the container again.
    public static let pauseSeconds: UInt32 = 3

    /// The next target from `current` toward `final`; exactly `final` when no
    /// further step is needed.
    public static func nextTarget(from current: Int64, to final: Int64, map: APFSSpaceMap?, budget: Int64) -> Int64 {
        guard current > final else { return final }
        var boundary: Int64
        if let map, map.containerBytes == current {
            boundary = map.lowestBoundary(above: final, below: current, budget: budget)
        } else {
            boundary = current - fallbackStepBytes / startingBudget * max(minimumBudget, budget)
        }
        // Rounding up moves the boundary toward `current`: less data, never more.
        boundary = alignUp(max(boundary, 0), to: alignment)
        // Always make progress, even through one dense MiB.
        if boundary >= current { boundary = alignDown(current - 1, to: alignment) }
        return max(final, boundary)
    }

    /// Steps estimated from `current` to `final` at a constant budget.
    public static func count(from current: Int64, to final: Int64, map: APFSSpaceMap?, budget: Int64) -> Int {
        var position = current, steps = 0
        while position > final && steps < 100_000 {
            // The map describes the container as it is now; later steps keep its
            // chunk counts, so pass it only through a view cut at `position`.
            let next = nextTarget(from: position, to: final, map: map.flatMap { $0.cut(at: position) }, budget: budget)
            position = next; steps += 1
        }
        return steps
    }

    /// Halves the budget after a slow call, grows it back after a fast one,
    /// never below the floor or above the starting budget.
    public static func adjustedBudget(_ budget: Int64, afterCallSeconds seconds: Double) -> Int64 {
        if seconds > slowCallSeconds { return max(minimumBudget, budget / 2) }
        if seconds < fastCallSeconds { return min(startingBudget, budget * 2) }
        return budget
    }
}

extension APFSSpaceMap {
    /// The same map ending at `bytes` (a whole number of blocks), as a planning
    /// view of the container after a shrink; data past the end is not moved
    /// into it here, which only matters for estimates.
    func cut(at bytes: Int64) -> APFSSpaceMap? {
        guard bytes > 0, bytes % blockSize == 0, bytes <= containerBytes else { return nil }
        if bytes == containerBytes { return self }
        let end = bytes / blockSize
        let kept = chunks.compactMap { chunk -> Chunk? in
            guard chunk.firstBlock < end else { return nil }
            let count = min(chunk.blockCount, end - chunk.firstBlock)
            return Chunk(firstBlock: chunk.firstBlock, blockCount: count, freeBlocks: max(0, count - chunk.allocatedBlocks))
        }
        return try? APFSSpaceMap(blockSize: blockSize, blockCount: end, chunks: kept)
    }
}
