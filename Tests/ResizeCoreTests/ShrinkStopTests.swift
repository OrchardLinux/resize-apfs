import XCTest
import Foundation
@testable import ResizeCore

final class ShrinkStopTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func operation(step: OperationStep = .shrinkAPFS, from: Int64? = nil, to: Int64? = nil,
                           observed: Int64? = nil) throws -> ResizeCore.Operation {
        let layout = StorageLayout.fixture()
        let plan = try Planner.make(PlanRequest(revision: layout.revision, requestedBytes: 24_000_000_000, createLinux: false), on: layout)
        let progress = to.map { APFSStepProgress(number: 4, plannedCount: 12, fromBytes: from ?? layout.containerBytes, targetBytes: $0,
                                                 dataBudgetBytes: nil, previousCallSeconds: 26) }
        return ResizeCore.Operation(id: UUID(), requestID: UUID(), plan: plan, status: .running,
                                    stepIndex: plan.steps.firstIndex(of: step)!, completedSteps: [], startedAt: start, stepStartedAt: start,
                                    lastConfirmedAt: nil, observedCapacityBytes: observed, observedAt: nil, workerPID: 1, message: nil,
                                    apfsStep: progress)
    }

    // MARK: When a stop is possible

    func testOnlyARunningShrinkWithStepsLeftCanStop() throws {
        var op = try operation()
        XCTAssertTrue(op.canStop, "before its first step")
        op = try operation(to: 28_600_000_000)
        XCTAssertTrue(op.canStop)
        op.stopRequested = true
        XCTAssertFalse(op.canStop, "already stopping")
        op = try operation(to: op.plan.targetBytes)
        XCTAssertTrue(op.onLastShrinkStep)
        XCTAssertFalse(op.canStop, "the last step ends at the target")
        XCTAssertFalse(try operation(step: .checking).canStop)
        XCTAssertFalse(try operation(step: .shrinkPartition, to: 24_000_000_000).canStop)
        op = try operation(to: 28_600_000_000)
        op.status = .unknown
        XCTAssertFalse(op.canStop)
    }

    // MARK: Progress

    func testProgressCountsOnlyTheObservedContainerSize() throws {
        let before = StorageLayout.fixture().containerBytes
        let fresh = try XCTUnwrap(try operation().shrinkProgress)
        XCTAssertEqual(fresh.releasedBytes, 0)
        XCTAssertEqual(fresh.stepBytes, 0)
        XCTAssertEqual(fresh.percent, 0)
        let op = try operation(from: before - 2_400_000_000, to: before - 3_000_000_000, observed: before - 2_400_000_000)
        let progress = try XCTUnwrap(op.shrinkProgress)
        XCTAssertEqual(progress.totalBytes, before - op.plan.targetBytes)
        XCTAssertEqual(progress.releasedBytes, 2_400_000_000)
        XCTAssertEqual(progress.stepBytes, 600_000_000)
        XCTAssertNil(try operation(step: .verifyLayout, to: 24_000_000_000).shrinkProgress)
    }

    func testProgressReads100OnlyAtTheTarget() throws {
        let target = try operation().plan.targetBytes
        XCTAssertEqual(try operation(to: target, observed: target + 4096).shrinkProgress?.percent, 99)
        XCTAssertEqual(try operation(to: target, observed: target).shrinkProgress?.percent, 100)
    }

    // MARK: Ending

    func testAStoppedShrinkReportsTheReachedSizeAndTheUnchangedPartition() throws {
        var op = try operation(to: 28_600_000_000)
        var layout = StorageLayout.fixture()
        layout.containerBytes = 28_600_000_000
        op.endStopped(on: layout, steps: 4)
        XCTAssertEqual(op.status, .stopped)
        XCTAssertEqual(op.stoppedByUser, true)
        XCTAssertNil(op.workerPID)
        let message = op.message ?? ""
        XCTAssertTrue(message.contains(Capacity.gb(28_600_000_000)) && message.contains("after 4 steps"), message)
        XCTAssertTrue(message.contains(Capacity.gb(layout.backingBytes)), message)
        op.endStopped(on: .fixture(), steps: 0)
        XCTAssertTrue(op.message?.contains("before the first step") == true, op.message ?? "")
    }

    func testRecordsWithoutAStopStillDecode() throws {
        let data = try JSONEncoder().encode(try operation())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("stopRequested"))
        let decoded = try JSONDecoder().decode(ResizeCore.Operation.self, from: data)
        XCTAssertNil(decoded.stopRequested)
        XCTAssertNil(decoded.stoppedByUser)
    }

    // MARK: Mock service

    private func running() async throws -> (MockEngine, ResizeCore.Operation) {
        let engine = try MockEngine()
        let snapshot = try await engine.snapshot(at: start)
        let plan = try await engine.plan(PlanRequest(revision: snapshot.layout.revision, requestedBytes: 24_000_000_000, createLinux: false))
        let started = try await engine.start(StartRequest(planID: plan.id, requestID: UUID()), at: start)
        return (engine, try XCTUnwrap(started.operation))
    }
    /// Ticks until `done`, 0.5 s apart.
    private func tick(_ engine: MockEngine, until done: (ServiceSnapshot) -> Bool) async throws -> (ServiceSnapshot, Date) {
        for index in 1...400 {
            let now = start.addingTimeInterval(Double(index) * 0.5)
            try await engine.tick(at: now)
            let snapshot = try await engine.snapshot(at: now, allowOutage: false)
            if done(snapshot) { return (snapshot, now) }
        }
        throw ResizeError("The mock never got there.")
    }

    func testStoppingFinishesTheRunningStepAndLeavesThePartition() async throws {
        let (engine, op) = try await running()
        let (during, _) = try await tick(engine) { $0.operation?.apfsStep?.number == 2 }
        let target = try XCTUnwrap(during.operation?.apfsStep?.targetBytes)
        XCTAssertGreaterThan(target, op.plan.targetBytes)
        let asked = try await engine.stop(StopRequest(operationID: op.id), at: start)
        XCTAssertEqual(asked.operation?.stopRequested, true)
        XCTAssertEqual(asked.operation?.status, .running, "the running step is not interrupted")
        let (ended, _) = try await tick(engine) { $0.operation?.status != .running }
        XCTAssertEqual(ended.operation?.status, .stopped)
        XCTAssertEqual(ended.operation?.stoppedByUser, true)
        XCTAssertEqual(ended.layout.containerBytes, target)
        XCTAssertEqual(ended.layout.partitions, op.plan.before.partitions)
        XCTAssertTrue(ended.operation?.message?.contains("after 2 steps") == true, ended.operation?.message ?? "")
    }

    func testAfterAStopTheUserCanContinueKeepOrGrowBack() async throws {
        let (engine, op) = try await running()
        _ = try await tick(engine) { $0.operation?.apfsStep?.number == 1 }
        _ = try await engine.stop(StopRequest(operationID: op.id), at: start)
        let (ended, _) = try await tick(engine) { $0.operation?.status == .stopped }
        func steps(_ bytes: Int64) async throws -> [OperationStep] {
            try await engine.plan(PlanRequest(revision: ended.layout.revision, requestedBytes: bytes, createLinux: false)).steps
        }
        let further = try await steps(24_000_000_000), keep = try await steps(ended.layout.containerBytes), back = try await steps(ended.layout.backingBytes)
        XCTAssertEqual(further, [.checking, .preparing, .shrinkAPFS, .verifyAPFS, .shrinkPartition, .verifyLayout])
        XCTAssertEqual(keep, [.checking, .preparing, .shrinkPartition, .verifyLayout])
        XCTAssertEqual(back, [.checking, .preparing, .growAPFS, .verifyAPFS, .verifyLayout])
    }

    func testAStopOnTheLastStepOrForAnotherOperationChangesNothing() async throws {
        let (engine, op) = try await running()
        let other = try await engine.stop(StopRequest(operationID: UUID()), at: start)
        XCTAssertNil(other.operation?.stopRequested)
        _ = try await tick(engine) { $0.operation?.onLastShrinkStep == true }
        let late = try await engine.stop(StopRequest(operationID: op.id), at: start)
        XCTAssertNil(late.operation?.stopRequested)
        let (ended, _) = try await tick(engine) { $0.operation?.status != .running }
        XCTAssertEqual(ended.operation?.status, .completed)
        XCTAssertNil(ended.operation?.stoppedByUser)
    }
}
