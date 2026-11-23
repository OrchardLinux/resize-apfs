import XCTest
import Foundation
@testable import ResizeCore
import ResizeDevice

/// A completed, verified operation is history; only an unfinished one is an error.
final class OperationHistoryTests: XCTestCase {
    private struct Journal: Codable {
        var operation: ResizeCore.Operation
        var workerJob: URL?
        var bootIdentity: String
    }

    private func operation(_ status: OperationStatus, finished: Bool, message: String? = nil) throws -> ResizeCore.Operation {
        let layout = StorageLayout.fixture()
        let plan = try Planner.make(PlanRequest(revision: layout.revision, requestedBytes: 24_000_000_000, createLinux: true), on: layout)
        let done = finished ? plan.steps : Array(plan.steps.prefix(3))
        return ResizeCore.Operation(id: UUID(), requestID: UUID(), plan: plan, status: status, stepIndex: done.count,
                                    completedSteps: done, startedAt: Date(), stepStartedAt: Date(), lastConfirmedAt: nil,
                                    observedCapacityBytes: nil, observedAt: nil, workerPID: nil, message: message)
    }

    /// The final layout the plan produced, then the same with a Linux partition added after it.
    private func layouts(_ op: ResizeCore.Operation) -> (final: StorageLayout, changed: StorageLayout) {
        let final = op.plan.after
        var changed = final
        changed.partitions.removeAll { $0.kind == .linux }
        changed.revision = UUID()
        return (final, changed)
    }

    func testACompletedOperationIsReportedWhileItsLayoutStands() throws {
        let op = try operation(.completed, finished: true)
        XCTAssertTrue(op.finished)
        XCTAssertTrue(op.plan.produced(layouts(op).final))
        XCTAssertEqual(OperationHistory.reported(op, on: layouts(op).final), op)
    }

    func testACompletedOperationIsHistoryOnceTheLayoutChanged() throws {
        let op = try operation(.completed, finished: true)
        XCTAssertFalse(op.plan.produced(layouts(op).changed))
        XCTAssertNil(OperationHistory.reported(op, on: layouts(op).changed))
    }

    func testAnUnfinishedOperationIsAlwaysReported() throws {
        for status in [OperationStatus.stopped, .unknown, .running] {
            let op = try operation(status, finished: false)
            XCTAssertFalse(op.finished)
            XCTAssertEqual(OperationHistory.reported(op, on: layouts(op).changed), op)
            XCTAssertEqual(OperationHistory.restoringCompletion(op), op)
        }
    }

    func testAFinishedOperationAnOlderHelperMarkedStoppedIsCompletedAgain() throws {
        // operation.json from the iPod touch 6: all steps verified, status stopped.
        let op = try operation(.stopped, finished: true, message: "The previous operation completed, but the storage layout has changed since then.")
        let restored = OperationHistory.restoringCompletion(op)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.message, OperationHistory.completedMessage)
        XCTAssertEqual(restored.completedSteps, op.completedSteps)
        XCTAssertNil(OperationHistory.reported(restored, on: layouts(op).changed))
    }

    func testTheHelperTreatsSuchAJournalAsHistoryAndAllowsNewChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DiskFixture(directory: directory.appendingPathComponent("disk"))
        let state = directory.appendingPathComponent("helper")
        let journal = state.appendingPathComponent("operation.json")
        let op = try operation(.stopped, finished: true, message: "The previous operation completed, but the storage layout has changed since then.")
        try DeviceJournal.write(Journal(operation: op, workerJob: nil, bootIdentity: "an-earlier-boot"), to: journal)
        let engine = try DeviceEngine(source: fixture.source, directory: state, executable: "/nonexistent")
        XCTAssertEqual(try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journal)).operation.status, .completed)
        engine.refresh()
        let snapshot = try engine.snapshot()
        XCTAssertNil(snapshot.operation, "the fixture's layout is not the one the plan produced")
        XCTAssertNoThrow(try engine.plan(PlanRequest(revision: snapshot.layout.revision, requestedBytes: fixture.containerBytes,
                                                     createLinux: true)))
        // History stays history: refreshing again does not turn it into an error.
        engine.refresh()
        XCTAssertEqual(try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journal)).operation.status, .completed)
    }

    func testTheHelperStillReportsAnUnfinishedOperationWhoseLayoutChanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DiskFixture(directory: directory.appendingPathComponent("disk"))
        let state = directory.appendingPathComponent("helper")
        let op = try operation(.stopped, finished: false, message: "The partition update failed.")
        try DeviceJournal.write(Journal(operation: op, workerJob: nil, bootIdentity: "an-earlier-boot"),
                                to: state.appendingPathComponent("operation.json"))
        let engine = try DeviceEngine(source: fixture.source, directory: state, executable: "/nonexistent")
        engine.refresh()
        XCTAssertEqual(try engine.snapshot().operation?.status, .stopped)
        XCTAssertEqual(try engine.snapshot().operation?.message, "The partition update failed.")
    }
}
