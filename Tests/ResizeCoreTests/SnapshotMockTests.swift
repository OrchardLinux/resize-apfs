import XCTest
@testable import ResizeCore

final class SnapshotMockTests: XCTestCase {
    func testNoSnapshotScenarioReportsNone() async throws {
        let engine = try MockEngine(scenario: .normal)
        let snapshot = try await engine.snapshot(allowOutage: false)
        XCTAssertNil(snapshot.layout.systemSnapshot)
    }

    func testRemovingTheSnapshotLowersTheMinimumAndAllowsTheShrink() async throws {
        let engine = try MockEngine(scenario: .snapshot)
        let before = try await engine.snapshot(allowOutage: false)
        XCTAssertEqual(before.layout.systemSnapshot, SystemSnapshot(present: true, removable: true, heldBytes: 10_100_000_000))
        // With the snapshot, 24 GB is below the minimum the APFS query reports.
        do {
            _ = try await engine.plan(PlanRequest(revision: before.layout.revision, requestedBytes: 24_000_000_000, createLinux: false))
            XCTFail("24 GB must be refused while orig-fs holds the minimum at 29.6 GB")
        } catch {}
        let after = try await engine.removeSnapshot(SnapshotRequest(revision: before.layout.revision, name: "orig-fs"))
        XCTAssertEqual(after.layout.systemSnapshot?.present, false)
        XCTAssertLessThan(after.layout.minimumContainerBytes!, before.layout.minimumContainerBytes!)
        XCTAssertNotEqual(after.layout.revision, before.layout.revision)
        _ = try await engine.plan(PlanRequest(revision: after.layout.revision, requestedBytes: 24_000_000_000, createLinux: false))
        // A new one can be taken once it is gone, and only then.
        let retaken = try await engine.takeSnapshot(SnapshotRequest(revision: after.layout.revision, name: "orig-fs"))
        XCTAssertEqual(retaken.layout.systemSnapshot?.present, true)
        do {
            _ = try await engine.takeSnapshot(SnapshotRequest(revision: retaken.layout.revision, name: "orig-fs"))
            XCTFail("a second orig-fs must be refused")
        } catch {}
    }

    func testProtectedSnapshotIsNeverRemoved() async throws {
        let engine = try MockEngine(scenario: .snapshotProtected)
        let before = try await engine.snapshot(allowOutage: false)
        XCTAssertEqual(before.layout.systemSnapshot?.removable, false)
        do {
            _ = try await engine.removeSnapshot(SnapshotRequest(revision: before.layout.revision, name: "orig-fs"))
            XCTFail("the revert target must not be removed")
        } catch {}
        let unchanged = try await engine.snapshot(allowOutage: false)
        XCTAssertEqual(unchanged.layout.systemSnapshot?.present, true)
    }

    func testStaleViewOrActiveOperationRefusesRemoval() async throws {
        let engine = try MockEngine(scenario: .snapshot)
        let before = try await engine.snapshot(allowOutage: false)
        do {
            _ = try await engine.removeSnapshot(SnapshotRequest(revision: UUID(), name: "orig-fs"))
            XCTFail("a stale view must be refused")
        } catch {}
        let plan = try await engine.plan(PlanRequest(revision: before.layout.revision, requestedBytes: 30_000_000_000, createLinux: false))
        _ = try await engine.start(StartRequest(planID: plan.id, requestID: UUID()))
        let running = try await engine.snapshot(allowOutage: false)
        do {
            _ = try await engine.removeSnapshot(SnapshotRequest(revision: running.layout.revision, name: "orig-fs"))
            XCTFail("no removal while a resize runs")
        } catch {}
    }
}
