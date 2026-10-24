import XCTest
@testable import ResizeCore

final class PlannerTests: XCTestCase {
    func request(_ layout: StorageLayout, _ bytes: Int64, linux: Bool = false) -> PlanRequest {
        PlanRequest(revision: layout.revision, requestedBytes: bytes, createLinux: linux)
    }
    func testShrinkOrderAndPreservedIdentity() throws {
        let before = StorageLayout.fixture()
        let plan = try Planner.make(request(before, 24_000_000_000, linux: true), on: before)
        XCTAssertEqual(plan.steps, [.checking, .preparing, .shrinkAPFS, .verifyAPFS, .shrinkPartition, .createLinux, .verifyLayout])
        XCTAssertEqual(plan.after.apfs.id, before.apfs.id)
        XCTAssertEqual(plan.after.apfs.firstLBA, before.apfs.firstLBA)
        XCTAssertEqual(plan.after.partitions[0], before.partitions[0])
        XCTAssertEqual(plan.after.containerID, before.containerID)
        XCTAssertEqual(plan.after.diskID, before.diskID)
        XCTAssertEqual(plan.after.containerBytes, 24_000_000_000)
        let linux = try XCTUnwrap(plan.after.partitions.first { $0.kind == .linux })
        XCTAssertEqual(linux.typeGUID, linuxTypeGUID)
        XCTAssertEqual(linux.contents, "Not formatted by Resize APFS")
        XCTAssertEqual(linux.firstLBA % 8, 0)
        XCTAssertGreaterThan(linux.firstLBA, plan.after.apfs.lastLBA)
        XCTAssertEqual(linux.lastLBA, before.lastUsableLBA)
        try plan.after.validate()
    }
    func testGrowthExpandsPartitionFirst() throws {
        let before = StorageLayout.fixture(.freeSpace)
        let plan = try Planner.make(request(before, 28_000_000_000), on: before)
        XCTAssertEqual(plan.steps, [.checking, .preparing, .expandPartition, .verifyPartition, .growAPFS, .verifyAPFS, .verifyLayout])
    }
    func testMismatchedSizesDoNotRequireAlignmentFirst() throws {
        let before = StorageLayout.fixture(.mismatch)
        let plan = try Planner.make(request(before, 28_000_000_000), on: before)
        XCTAssertEqual(plan.steps, [.checking, .preparing, .growAPFS, .verifyAPFS, .shrinkPartition, .verifyLayout])
        let partitionOnly = try Planner.make(request(before, before.containerBytes), on: before)
        XCTAssertEqual(partitionOnly.steps, [.checking, .preparing, .shrinkPartition, .verifyLayout])
    }
    func testPartitionCreationWithoutResize() throws {
        let before = StorageLayout.fixture(.freeSpace)
        let plan = try Planner.make(request(before, before.containerBytes, linux: true), on: before)
        XCTAssertEqual(plan.steps, [.checking, .preparing, .createLinux, .verifyLayout])
    }
    func testInvalidAndStalePlansRejected() throws {
        let before = StorageLayout.fixture()
        XCTAssertThrowsError(try Planner.make(request(before, 1), on: before))
        XCTAssertThrowsError(try Planner.make(request(before, -1), on: before))
        XCTAssertThrowsError(try Planner.make(request(before, Int64.max), on: before))
        XCTAssertThrowsError(try Planner.make(PlanRequest(revision: UUID(), requestedBytes: 24_000_000_000, createLinux: false), on: before))
        XCTAssertThrowsError(try Planner.make(request(before, before.containerBytes), on: before))
        let blocked = StorageLayout.fixture(.linuxBlocked)
        XCTAssertThrowsError(try Planner.make(request(blocked, 28_000_000_000), on: blocked))
        let invalid = StorageLayout.fixture(.invalidLayout)
        XCTAssertThrowsError(try Planner.make(request(invalid, 24_000_000_000), on: invalid))
    }
    func testAlignmentAndUnknownMinimum() throws {
        var before = StorageLayout.fixture()
        let plan = try Planner.make(request(before, 24_000_000_001), on: before)
        XCTAssertTrue(plan.alignmentChanged)
        XCTAssertEqual(plan.targetBytes, 24_000_000_000)
        before.minimumContainerBytes = nil
        XCTAssertThrowsError(try Planner.make(request(before, 24_000_000_000), on: before))
    }
    func testParsing() {
        XCTAssertEqual(Capacity.parseGB("24"), 24_000_000_000)
        XCTAssertEqual(Capacity.parseGB("24,5"), 24_500_000_000)
        XCTAssertNil(Capacity.parseGB("-1"))
        XCTAssertNil(Capacity.parseGB("99999999999999999999999"))
    }
    func testGeometryRejectsOverlapAndContainerOutsidePartition() {
        var layout = StorageLayout.fixture()
        layout.partitions[0].lastLBA = layout.apfs.firstLBA
        XCTAssertThrowsError(try layout.validate())
        layout = .fixture()
        layout.containerBytes = layout.backingBytes + 4096
        XCTAssertThrowsError(try layout.validate())
    }
}

final class EngineTests: XCTestCase {
    let initial = Date(timeIntervalSince1970: 1_000_000)
    func begin(_ engine: MockEngine, target: Int64 = 24_000_000_000, linux: Bool = false) async throws -> ServiceSnapshot {
        let snapshot = try await engine.snapshot(at: initial)
        let plan = try await engine.plan(PlanRequest(revision: snapshot.layout.revision, requestedBytes: target, createLinux: linux))
        return try await engine.start(StartRequest(planID: plan.id, requestID: UUID()), at: initial)
    }
    func finish(_ engine: MockEngine) async throws -> ServiceSnapshot {
        for index in 1...12 { try await engine.tick(at: initial.addingTimeInterval(Double(index) * 100)) }
        return try await engine.snapshot(at: initial.addingTimeInterval(1300), allowOutage: false)
    }
    func testCompleteShrinkAndLinuxCreation() async throws {
        let engine = try MockEngine()
        _ = try await begin(engine, linux: true)
        let result = try await finish(engine)
        XCTAssertEqual(result.operation?.status, .completed)
        XCTAssertEqual(result.layout.containerBytes, 24_000_000_000)
        XCTAssertEqual(result.layout.backingBytes, 24_000_000_000)
        XCTAssertTrue(result.layout.partitions.contains { $0.kind == .linux })
        try result.layout.validate()
    }
    func testCompleteGrowth() async throws {
        let engine = try MockEngine(scenario: .freeSpace)
        _ = try await begin(engine, target: 28_000_000_000)
        let result = try await finish(engine)
        XCTAssertEqual(result.operation?.status, .completed)
        XCTAssertEqual(result.layout.backingBytes, alignDown(28_000_000_000, to: 4096))
    }
    func testNoCapacityInterpolationAndHeartbeatIsRealObservation() async throws {
        let engine = try MockEngine(scenario: .longSilence, workerPID: 123)
        let before = try await begin(engine)
        try await engine.tick(at: initial.addingTimeInterval(1))
        try await engine.tick(at: initial.addingTimeInterval(2))
        try await engine.tick(at: initial.addingTimeInterval(30))
        let result = try await engine.snapshot(at: initial.addingTimeInterval(30))
        XCTAssertEqual(result.operation?.currentStep, .shrinkAPFS)
        XCTAssertEqual(result.layout.containerBytes, before.layout.containerBytes)
        XCTAssertEqual(result.operation?.lastConfirmedAt, initial.addingTimeInterval(30))
        XCTAssertEqual(result.operation?.workerPID, 123)
    }
    func testPartialFailurePreservesVerifiedState() async throws {
        let engine = try MockEngine(scenario: .partitionError)
        let before = try await begin(engine)
        let result = try await finish(engine)
        XCTAssertEqual(result.operation?.status, .stopped)
        XCTAssertEqual(result.layout.containerBytes, 24_000_000_000)
        XCTAssertEqual(result.layout.backingBytes, before.layout.backingBytes)
        XCTAssertTrue(result.operation?.completedSteps.contains(.verifyAPFS) == true)
        XCTAssertFalse(result.operation?.completedSteps.contains(.shrinkPartition) == true)
        let newPlan = try await engine.plan(PlanRequest(revision: result.layout.revision, requestedBytes: 28_000_000_000, createLinux: false))
        XCTAssertEqual(newPlan.steps[2], .growAPFS)
    }
    func testErrorDoesNotProceedToGPT() async throws {
        let engine = try MockEngine(scenario: .resizeError)
        let before = try await begin(engine)
        let result = try await finish(engine)
        XCTAssertEqual(result.operation?.status, .stopped)
        XCTAssertEqual(result.layout, before.layout)
    }
    func testUnknownOutcomeBlocksNewOperation() async throws {
        let engine = try MockEngine(scenario: .workerCrash)
        _ = try await begin(engine)
        let result = try await finish(engine)
        XCTAssertEqual(result.operation?.status, .unknown)
        do {
            _ = try await engine.plan(PlanRequest(revision: result.layout.revision, requestedBytes: 24_000_000_000, createLinux: false))
            XCTFail("Must not allow a blind retry")
        } catch {}
    }
    func testLostConnectionDoesNotStopWorker() async throws {
        let engine = try MockEngine(scenario: .disconnect)
        _ = try await begin(engine)
        do { _ = try await engine.snapshot(at: initial.addingTimeInterval(5)); XCTFail("Expected outage") }
        catch {}
        let result = try await finish(engine)
        XCTAssertEqual(result.operation?.status, .completed)
    }
    func testStartIsIdempotentAndBusyRejectsDifferentRequest() async throws {
        let engine = try MockEngine()
        let before = try await engine.snapshot()
        let plan = try await engine.plan(PlanRequest(revision: before.layout.revision, requestedBytes: 24_000_000_000, createLinux: false))
        let request = StartRequest(planID: plan.id, requestID: UUID())
        let first = try await engine.start(request, at: initial)
        let second = try await engine.start(request, at: initial)
        XCTAssertEqual(first.operation?.id, second.operation?.id)
        do { _ = try await engine.start(StartRequest(planID: plan.id, requestID: UUID())); XCTFail("Expected busy") }
        catch {}
    }
    func testRestartDoesNotInventLiveWorkerOrRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let first = try MockEngine(stateURL: url)
        let started = try await begin(first)
        let restarted = try MockEngine(stateURL: url)
        let snapshot = try await restarted.snapshot()
        XCTAssertEqual(snapshot.operation?.id, started.operation?.id)
        XCTAssertEqual(snapshot.operation?.status, .unknown)
        XCTAssertNil(snapshot.operation?.workerPID)
        XCTAssertEqual(snapshot.layout, started.layout)
    }
    func testWorkflowReopensCompletedAndDoesNotPermitEditingUnknown() async throws {
        let engine = try MockEngine()
        let running = try await begin(engine)
        var machine = WorkflowMachine()
        machine.receive(running)
        XCTAssertEqual(machine.state, .running)
        XCTAssertThrowsError(try machine.edit())
        machine.connectionLost()
        XCTAssertEqual(machine.state, .reconnecting)
        machine.receive(running)
        XCTAssertEqual(machine.state, .running)
        let finished = try await finish(engine)
        machine.receive(finished)
        XCTAssertEqual(machine.state, .completed)
        try machine.acknowledge(XCTUnwrap(finished.operation))
        machine.receive(finished)
        XCTAssertEqual(machine.state, .overview)
        try machine.edit(); try machine.review(); try machine.submit()
        XCTAssertEqual(machine.state, .submitting)
    }
}
