import XCTest
import Foundation
@testable import ResizeCore
import ResizeDevice

private let GiB: Int64 = 1 << 30
private let MiB: Int64 = 1 << 20

/// A space map with 128 MiB chunks; `allocated` gives each chunk's allocated fraction.
private func map(_ bytes: Int64, _ allocated: (Int) -> Double) throws -> APFSSpaceMap {
    let block: Int64 = 4096, perChunk: Int64 = 32_768, blocks = bytes / block
    var chunks: [APFSSpaceMap.Chunk] = []
    var first: Int64 = 0
    while first < blocks {
        let count = min(perChunk, blocks - first)
        let used = Int64(Double(count) * allocated(chunks.count))
        chunks.append(.init(firstBlock: first, blockCount: count, freeBlocks: count - used))
        first += count
    }
    return try APFSSpaceMap(blockSize: block, blockCount: blocks, chunks: chunks)
}

/// The whole sequence of targets, re-reading a cut of the map before each step
/// as the helper re-reads the disk.
private func plannedTargets(from current: Int64, to final: Int64, map: APFSSpaceMap?, budget: Int64 = ShrinkSteps.startingBudget) -> [Int64] {
    var position = current, targets: [Int64] = []
    while position > final && targets.count < 10_000 {
        position = ShrinkSteps.nextTarget(from: position, to: final, map: map?.cut(at: position), budget: budget)
        targets.append(position)
    }
    return targets
}

final class ShrinkStepsTests: XCTestCase {
    func testEmptyRegionIsCrossedInOneStep() throws {
        // 64 GiB with data only in the first 10 GiB: nothing to move above 16 GiB.
        let space = try map(64 * GiB) { $0 < 80 ? 1 : 0 }
        XCTAssertEqual(plannedTargets(from: 64 * GiB, to: 16 * GiB, map: space), [16 * GiB])
        XCTAssertEqual(ShrinkSteps.count(from: 64 * GiB, to: 16 * GiB, map: space, budget: ShrinkSteps.startingBudget), 1)
    }

    func testDenseDataIsSplitByTheBudget() throws {
        let space = try map(64 * GiB) { _ in 1 }
        let targets = plannedTargets(from: 64 * GiB, to: 16 * GiB, map: space)
        XCTAssertEqual(targets.first, 63 * GiB)
        XCTAssertEqual(targets.count, 48)
        XCTAssertEqual(ShrinkSteps.count(from: 64 * GiB, to: 16 * GiB, map: space, budget: ShrinkSteps.startingBudget), 48)
        var previous = 64 * GiB
        for target in targets {
            XCTAssertLessThanOrEqual(space.allocatedBytes(from: target, to: previous), ShrinkSteps.startingBudget)
            previous = target
        }
    }

    func testEmptyGapThenDenseTailSharesOneStep() throws {
        // Dense top 1 GiB, empty below it down to 20 GiB, dense again under that.
        let space = try map(64 * GiB) { $0 >= 504 || $0 < 160 ? 1 : 0 }
        let targets = plannedTargets(from: 64 * GiB, to: 16 * GiB, map: space)
        // The 1 GiB at the top fills the first 1 GiB budget; the empty gap comes free.
        XCTAssertEqual(targets.first, 20 * GiB)
        XCTAssertEqual(targets.last, 16 * GiB)
        XCTAssertEqual(targets.count, 5)
    }

    func testHalfFullChunkCountsAsFullWherePartlyCrossed() throws {
        let space = try map(1 * GiB) { _ in 0.5 } // 64 MiB in each 128 MiB chunk
        XCTAssertEqual(space.allocatedBytes(from: 0, to: 1 * GiB), 512 * MiB)
        XCTAssertEqual(space.allocatedBytes(from: 1 * GiB - 32 * MiB, to: 1 * GiB), 32 * MiB)
        XCTAssertEqual(space.allocatedBytes(from: 1 * GiB - 96 * MiB, to: 1 * GiB), 64 * MiB)
    }

    func testFallsBackToFixedStepsWithoutAUsableMap() throws {
        XCTAssertEqual(plannedTargets(from: 64 * GiB, to: 16 * GiB, map: nil), [56, 48, 40, 32, 24, 16].map { $0 * GiB })
        // A map of a different container size is not used.
        let other = try map(32 * GiB) { _ in 0 }
        XCTAssertEqual(ShrinkSteps.nextTarget(from: 64 * GiB, to: 16 * GiB, map: other, budget: ShrinkSteps.startingBudget), 56 * GiB)
        // Fixed steps shrink with the budget after slow calls.
        XCTAssertEqual(ShrinkSteps.nextTarget(from: 64 * GiB, to: 16 * GiB, map: nil, budget: 512 * MiB), 60 * GiB)
        XCTAssertEqual(ShrinkSteps.nextTarget(from: 64 * GiB, to: 16 * GiB, map: nil, budget: ShrinkSteps.minimumBudget), 62 * GiB)
    }

    func testInconsistentMapsAreRefused() {
        XCTAssertThrowsError(try APFSSpaceMap(blockSize: 4096, blockCount: 100, chunks: [.init(firstBlock: 0, blockCount: 50, freeBlocks: 0)]))
        XCTAssertThrowsError(try APFSSpaceMap(blockSize: 4096, blockCount: 100, chunks: [
            .init(firstBlock: 0, blockCount: 50, freeBlocks: 0), .init(firstBlock: 60, blockCount: 40, freeBlocks: 0)]))
        XCTAssertThrowsError(try APFSSpaceMap(blockSize: 4096, blockCount: 50, chunks: [.init(firstBlock: 0, blockCount: 50, freeBlocks: 51)]))
    }

    func testBudgetHalvesWhenSlowAndGrowsBackNoHigherThanTheStart() {
        var budget = ShrinkSteps.startingBudget
        budget = ShrinkSteps.adjustedBudget(budget, afterCallSeconds: 31); XCTAssertEqual(budget, 512 * MiB)
        budget = ShrinkSteps.adjustedBudget(budget, afterCallSeconds: 20); XCTAssertEqual(budget, 512 * MiB)
        for _ in 0..<10 { budget = ShrinkSteps.adjustedBudget(budget, afterCallSeconds: 94) }
        XCTAssertEqual(budget, ShrinkSteps.minimumBudget)
        budget = ShrinkSteps.adjustedBudget(budget, afterCallSeconds: 4); XCTAssertEqual(budget, 512 * MiB)
        for _ in 0..<10 { budget = ShrinkSteps.adjustedBudget(budget, afterCallSeconds: 1) }
        XCTAssertEqual(budget, ShrinkSteps.startingBudget)
    }

    func testEndsExactlyAtTheTargetWithAlignedIntermediateSteps() throws {
        let final = alignDown(16_000_000_000, to: 4096)
        for space in [try map(64 * GiB) { _ in 1 }, try map(64 * GiB) { $0 % 3 == 0 ? 0.9 : 0.1 }, nil] {
            let targets = plannedTargets(from: 64 * GiB, to: final, map: space)
            XCTAssertEqual(targets.last, final)
            for (index, target) in targets.enumerated() {
                XCTAssertGreaterThanOrEqual(target, final)
                if index > 0 { XCTAssertLessThan(target, targets[index - 1]) }
                if target != final { XCTAssertEqual(target % ShrinkSteps.alignment, 0) }
            }
        }
        // Growth or no change needs no step.
        XCTAssertEqual(ShrinkSteps.nextTarget(from: 16 * GiB, to: 16 * GiB, map: nil, budget: GiB), 16 * GiB)
        XCTAssertEqual(ShrinkSteps.count(from: 16 * GiB, to: 16 * GiB, map: nil, budget: GiB), 0)
    }

    func testDenseMiBAlwaysProgresses() throws {
        let space = try map(1 * GiB) { _ in 1 }
        XCTAssertEqual(ShrinkSteps.nextTarget(from: 1 * GiB, to: 0, map: space, budget: 0), 1 * GiB - MiB)
    }

    // MARK: Reading the space manager

    /// A sparse 16 GiB container: superblock, checkpoint map, space manager and
    /// two chunk-info blocks for 128 chunks.
    private func container(freeTotal: ((UInt64) -> UInt64)? = nil, corruptCIB: Bool = false) -> (Int64, GPTImage.Reader) {
        let block = 4096, blocks: UInt64 = 16 * 262_144, perChunk: UInt64 = 32_768, xid: UInt64 = 42, smOID: UInt64 = 0x400
        let chunkCount = blocks / perChunk, perCIB = 126
        var objects: [UInt64: Data] = [:]
        func free(_ chunk: UInt64) -> UInt64 { chunk < 32 ? 0 : (chunk < 100 ? perChunk : perChunk / 2) }
        var nxsb = Data(count: block)
        nxsb.put64(1, at: 8); nxsb.put64(xid, at: 16); nxsb.put32(0x80000001, at: 24)
        nxsb.replaceSubrange(32..<36, with: "NXSB".utf8); nxsb.put32(UInt32(block), at: 36); nxsb.put64(blocks, at: 40)
        nxsb.put32(8, at: 104); nxsb.put64(1, at: 112); nxsb.put64(smOID, at: 152)
        var map = Data(count: block)
        map.put64(2, at: 8); map.put64(xid, at: 16); map.put32(0x8000000c, at: 24)
        map.put32(1, at: 32); map.put32(1, at: 36)
        map.put32(0x80000005, at: 40); map.put32(UInt32(block), at: 48); map.put64(smOID, at: 64); map.put64(10, at: 72)
        var totalFree: UInt64 = 0
        var cibs: [UInt64] = []
        for (index, start) in stride(from: 0, to: Int(chunkCount), by: perCIB).enumerated() {
            let address = UInt64(20 + index)
            var cib = Data(count: block)
            cib.put64(address, at: 8); cib.put64(xid - 1, at: 16); cib.put32(0x40000007, at: 24)
            let entries = min(perCIB, Int(chunkCount) - start)
            cib.put32(UInt32(index), at: 32); cib.put32(UInt32(entries), at: 36)
            for entry in 0..<entries {
                let chunk = UInt64(start + entry), at = 40 + entry * 32
                cib.put64(xid - 1, at: at); cib.put64(chunk * perChunk, at: at + 8)
                cib.put32(UInt32(perChunk), at: at + 16); cib.put32(UInt32(free(chunk)), at: at + 20)
                totalFree += free(chunk)
            }
            if corruptCIB && index == 1 { cib.put32(UInt32(perChunk), at: 40 + 20) }
            objects[address] = DiskFixture.seal(cib)
            cibs.append(address)
        }
        var sm = Data(count: block)
        sm.put64(smOID, at: 8); sm.put64(xid, at: 16); sm.put32(0x80000005, at: 24)
        sm.put32(UInt32(block), at: 32); sm.put32(UInt32(perChunk), at: 36); sm.put32(UInt32(perCIB), at: 40)
        sm.put64(blocks, at: 48); sm.put64(chunkCount, at: 56); sm.put32(UInt32(cibs.count), at: 64); sm.put32(0, at: 68)
        sm.put64(freeTotal?(totalFree) ?? totalFree, at: 72); sm.put32(1024, at: 80)
        for (index, address) in cibs.enumerated() { sm.put64(address, at: 1024 + index * 8) }
        objects[0] = DiskFixture.seal(nxsb); objects[1] = DiskFixture.seal(map); objects[2] = objects[0]
        objects[10] = DiskFixture.seal(sm)
        let bytes = Int64(blocks) * Int64(block)
        let read: GPTImage.Reader = { offset, count in
            var data = Data()
            var at = offset
            while data.count < count {
                let index = UInt64(at / Int64(block)), within = Int(at % Int64(block))
                let object = objects[index] ?? Data(count: block)
                let take = min(block - within, count - data.count)
                data.append(object[within..<(within + take)])
                at += Int64(take)
            }
            return data
        }
        return (bytes, read)
    }

    func testSpaceMapFromChunkInfoBlocks() throws {
        let (bytes, read) = container()
        let space = try APFSSpaceMap.capture(partitionBytes: bytes, read: read)
        XCTAssertEqual(space.containerBytes, 16 * GiB)
        XCTAssertEqual(space.chunks.count, 128)
        // Chunks 0-31 full (4 GiB), 32-99 empty, 100-127 half full (1.75 GiB).
        XCTAssertEqual(space.allocatedBytes(from: 0, to: 4 * GiB), 4 * GiB)
        XCTAssertEqual(space.allocatedBytes(from: 4 * GiB, to: 12_800 * MiB), 0)
        XCTAssertEqual(space.allocatedBytes(from: 12_800 * MiB, to: 16 * GiB), 1792 * MiB)
        let metadata = try APFSMetadata.capture(partitionBytes: bytes, read: read)
        XCTAssertEqual(metadata.allocatedBytes, 4 * GiB + 1792 * MiB)
        // 16 → 4 GiB: the half-full tail takes two budgets, the empty middle is free.
        XCTAssertEqual(plannedTargets(from: 16 * GiB, to: 4 * GiB, map: space), [14 * GiB, 4 * GiB])
    }

    func testSpaceMapRefusedWhenCountsDisagree() {
        let (bytes, read) = container(freeTotal: { $0 - 1 })
        XCTAssertThrowsError(try APFSSpaceMap.capture(partitionBytes: bytes, read: read))
        let (corruptBytes, corrupt) = container(corruptCIB: true)
        XCTAssertThrowsError(try APFSSpaceMap.capture(partitionBytes: corruptBytes, read: corrupt))
    }

    func testFixtureWithoutChunkInfoGivesNoMapSoStepsAreFixed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DiskFixture(directory: directory)
        let inspection = try DeviceInspector.inspect(fixture.source)
        XCTAssertNil(DeviceInspector.spaceMap(fixture.source, matching: inspection))
    }

    // MARK: Worker and journal

    func testWorkerAcceptsOnlyStepsBetweenTargetAndCurrentSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DiskFixture(directory: directory)
        let gpt = try DeviceInspector.inspect(fixture.source).gpt
        let layout = StorageLayout.fixture()
        let plan = try Planner.make(PlanRequest(revision: layout.revision, requestedBytes: 24_000_000_000, createLinux: false), on: layout)
        func job(_ target: Int64?, _ step: OperationStep = .shrinkAPFS) -> DeviceJob {
            DeviceJob(source: fixture.source, step: step, plan: plan, expectedGPT: gpt,
                      expectedContainerBytes: layout.containerBytes, apfsTargetBytes: target)
        }
        XCTAssertEqual(try DeviceWorker.validatedResizeTarget(job(28 * GiB), layout), 28 * GiB)
        XCTAssertEqual(try DeviceWorker.validatedResizeTarget(job(nil), layout), plan.targetBytes)
        XCTAssertThrowsError(try DeviceWorker.validatedResizeTarget(job(plan.targetBytes - 4096), layout))
        XCTAssertThrowsError(try DeviceWorker.validatedResizeTarget(job(layout.containerBytes), layout))
        var lowMinimum = layout
        lowMinimum.minimumContainerBytes = 25 * GiB
        XCTAssertThrowsError(try DeviceWorker.validatedResizeTarget(job(24 * GiB), lowMinimum))
        lowMinimum.minimumContainerBytes = nil
        XCTAssertThrowsError(try DeviceWorker.validatedResizeTarget(job(28 * GiB), lowMinimum))
        XCTAssertThrowsError(try DeviceWorker.validatedResizeTarget(job(28 * GiB, .growAPFS), layout))
    }

    private struct Journal: Codable {
        var operation: ResizeCore.Operation
        var workerJob: URL?
        var bootIdentity: String
    }

    func testRestartDuringAStepReportsItAndRepeatsNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DiskFixture(directory: directory.appendingPathComponent("disk"))
        let layout = StorageLayout.fixture()
        let plan = try Planner.make(PlanRequest(revision: layout.revision, requestedBytes: 24_000_000_000, createLinux: false), on: layout)
        let step = APFSStepProgress(number: 2, plannedCount: 5, fromBytes: 30 * GiB, targetBytes: 28 * GiB,
                                    dataBudgetBytes: ShrinkSteps.startingBudget, previousCallSeconds: 12)
        let operation = ResizeCore.Operation(id: UUID(), requestID: UUID(), plan: plan, status: .running,
                                             stepIndex: plan.steps.firstIndex(of: .shrinkAPFS)!, completedSteps: [.checking, .preparing],
                                             startedAt: Date(), stepStartedAt: Date(), lastConfirmedAt: nil,
                                             observedCapacityBytes: nil, observedAt: nil, workerPID: 999_999, message: nil,
                                             apfsStep: step)
        let state = directory.appendingPathComponent("helper")
        try DeviceJournal.write(Journal(operation: operation, workerJob: nil, bootIdentity: "an-earlier-boot"),
                                to: state.appendingPathComponent("operation.json"))
        let engine = try DeviceEngine(source: fixture.source, directory: state, executable: "/nonexistent")
        let saved = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: state.appendingPathComponent("operation.json")))
        XCTAssertEqual(saved.operation.status, .unknown)
        XCTAssertNil(saved.operation.workerPID)
        XCTAssertTrue(saved.operation.message?.contains("step 2 of 5") == true, saved.operation.message ?? "")
        XCTAssertEqual(saved.operation.apfsStep, step)
        engine.refresh()
        let snapshot = try engine.snapshot()
        XCTAssertEqual(snapshot.operation?.status, .stopped)
        XCTAssertEqual(snapshot.operation?.completedSteps, [.checking, .preparing])
        let message = snapshot.operation?.message ?? ""
        XCTAssertTrue(message.contains("step 2 of 5"), message)
        XCTAssertTrue(message.contains("APFS now measures \(Capacity.gb(fixture.containerBytes))"), message)
    }

    // MARK: Mock service

    func testMockShrinkShowsStepsAndEndsAtTheTarget() async throws {
        let engine = try MockEngine()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = try await engine.snapshot(at: start)
        let plan = try await engine.plan(PlanRequest(revision: snapshot.layout.revision, requestedBytes: 24_000_000_000, createLinux: false))
        _ = try await engine.start(StartRequest(planID: plan.id, requestID: UUID()), at: start)
        var seen: [APFSStepProgress] = []
        var capacities: [Int64] = []
        for index in 1...30 {
            try await engine.tick(at: start.addingTimeInterval(Double(index) * 100))
            let now = try await engine.snapshot(at: start.addingTimeInterval(Double(index) * 100), allowOutage: false)
            if let step = now.operation?.apfsStep, seen.last?.number != step.number { seen.append(step) }
            if capacities.last != now.layout.containerBytes { capacities.append(now.layout.containerBytes) }
        }
        let result = try await engine.snapshot(at: start.addingTimeInterval(4000), allowOutage: false)
        XCTAssertEqual(result.operation?.status, .completed, result.operation?.message ?? "")
        XCTAssertEqual(result.layout.containerBytes, plan.targetBytes)
        XCTAssertGreaterThan(seen.count, 1)
        XCTAssertEqual(seen.map(\.number), Array(1...seen.count))
        XCTAssertEqual(seen.first?.label, "Step 1 of \(seen.count)")
        XCTAssertEqual(seen.last?.targetBytes, plan.targetBytes)
        XCTAssertEqual(capacities.count, seen.count + 1)
    }
}
