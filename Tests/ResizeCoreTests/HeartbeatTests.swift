import XCTest
import Foundation
@testable import ResizeCore
import ResizeDevice

final class HeartbeatTests: XCTestCase {
    func testFifteenSecondFreshnessLimitNeverInventsLiveness() {
        let now = Date()
        XCTAssertTrue(WorkerConfirmation.isFresh(pid: 123, confirmedAt: now.addingTimeInterval(-15), connectionAvailable: true, now: now))
        XCTAssertFalse(WorkerConfirmation.isFresh(pid: 123, confirmedAt: now.addingTimeInterval(-15.01), connectionAvailable: true, now: now))
        XCTAssertFalse(WorkerConfirmation.isFresh(pid: 123, confirmedAt: now.addingTimeInterval(-120), connectionAvailable: true, now: now))
        XCTAssertFalse(WorkerConfirmation.isFresh(pid: nil, confirmedAt: now, connectionAvailable: true, now: now))
        XCTAssertFalse(WorkerConfirmation.isFresh(pid: 123, confirmedAt: now, connectionAvailable: false, now: now))
        XCTAssertFalse(WorkerConfirmation.isFresh(pid: 123, confirmedAt: nil, connectionAvailable: true, now: now))
    }

    func testNativeMonitorConfirmsAnActuallyLiveChildRepeatedly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raf-heartbeat-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DiskFixture(directory: directory)
        let worker = directory.appendingPathComponent("waiting-worker")
        // Test-only child: honor the real supervisor's startup gate, remain alive,
        // then exit without a completion report. It cannot write any disk data.
        try Data("#!/bin/sh\ndd bs=1 count=1 <&3 >/dev/null 2>&1 || exit 1\nsleep 5\nexit 0\n".utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let engine = try DeviceEngine(source: fixture.source, directory: directory.appendingPathComponent("state"), executable: worker.path)
        await engine.refresh()
        let initial = try await engine.snapshot()
        let plan = try await engine.plan(PlanRequest(revision: initial.layout.revision, requestedBytes: fixture.containerBytes, createLinux: false))
        _ = try await engine.start(StartRequest(planID: plan.id, requestID: UUID()))
        var first: ServiceSnapshot?
        for _ in 0..<40 {
            let current = try await engine.snapshot()
            if current.operation?.workerPID != nil { first = current; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let operation = try XCTUnwrap(first?.operation)
        let initialConfirmation = try XCTUnwrap(operation.lastConfirmedAt)
        var confirmations = Set<Date>()
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 650_000_000)
            let current = try await engine.snapshot()
            let op = try XCTUnwrap(current.operation)
            let confirmation = try XCTUnwrap(op.lastConfirmedAt)
            XCTAssertEqual(op.workerPID, operation.workerPID)
            XCTAssertGreaterThan(confirmation, initialConfirmation)
            XCTAssertLessThan(Date().timeIntervalSince(confirmation), 2)
            confirmations.insert(confirmation)
        }
        XCTAssertGreaterThanOrEqual(confirmations.count, 3)
        var final = try await engine.snapshot()
        for _ in 0..<40 {
            if final.operation?.status != .running { break }
            try await Task.sleep(nanoseconds: 100_000_000)
            final = try await engine.snapshot()
        }
        XCTAssertEqual(final.operation?.status, .unknown) // No report is not success.
        XCTAssertNil(final.operation?.workerPID)
        XCTAssertEqual(try DeviceInspector.inspect(fixture.source).layout.backingBytes, initial.layout.backingBytes)
    }
}
