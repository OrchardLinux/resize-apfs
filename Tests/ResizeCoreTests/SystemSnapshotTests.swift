import XCTest
@testable import ResizeCore
@testable import ResizeDevice

final class SystemSnapshotTests: XCTestCase {
    private typealias Volume = APFSSnapshotReport.VolumeDetail
    private typealias Snap = APFSSnapshotReport.SnapshotDetail
    // 4 KiB blocks, 32 GB container, as on the iPod touch 6.
    private let blockCount: Int64 = 7_714_844

    private func snap(_ name: String, tidemark: UInt64, rootTo: Bool = false, revertTo: Bool = false, note: String? = nil) -> Snap {
        Snap(name: name, xid: 7, extentrefTreeOID: 1, extentrefTreeType: 0, sblockOID: 2, flags: 0, isRootTo: rootTo, isRevertTo: revertTo,
             extentMinBlock: 1, extentMaxBlock: tidemark, treeNodeMaxBlock: nil, treeNodeCount: 1, effectiveTidemarkBlock: tidemark,
             effectiveTidemarkBytes: Int64(tidemark) * 4096, estimatedMinimumBytes: 0, parseNote: note)
    }
    private func volume(_ name: String, role: UInt16, oid: UInt64, live: UInt64, snapshots: [Snap]) -> Volume {
        Volume(index: Int(oid), fsOID: oid, name: name, uuid: UUID(), role: role, roleName: "", allocatedBlocks: 1, numSnapshots: UInt64(snapshots.count),
               rootToXID: 0, revertToXID: 0, omapMostRecentSnapXID: 0, liveExtentMinBlock: 1, liveExtentMaxBlock: live,
               snapshotOmapMaxBlock: nil, liveOmapMaxBlock: live, snapshots: snapshots, parseNote: nil)
    }
    private func report(_ volumes: [Volume]) -> APFSSnapshotReport {
        APFSSnapshotReport(containerID: UUID(), transactionID: 1, blockSize: 4096, blockCount: blockCount, maxFileSystems: 100,
                           alignmentBlocks: 256, maxSnapshotTidemarkBlock: 0, maxSnapshotTidemarkBytes: 0, estimatedSnapshotMinimumBytes: nil,
                           pinningVolume: nil, pinningSnapshot: nil, volumes: volumes)
    }
    private let minimum: Int64 = 29_600_000_000

    func testAbsentWhenTheMountedVolumeDoesNotListIt() {
        let state = SystemSnapshots.state(mounted: ["com.apple.os.update-1"], report: nil, minimumBytes: minimum)
        XCTAssertEqual(state, SystemSnapshot(present: false, removable: false))
    }

    func testNeverRemovableWithoutOnDiskConfirmation() {
        let state = SystemSnapshots.state(mounted: ["orig-fs"], report: nil, minimumBytes: minimum)
        XCTAssertTrue(state.present); XCTAssertFalse(state.removable); XCTAssertNil(state.heldBytes)
    }

    func testRevertAndBootTargetsAreNeverRemovable() {
        for (rootTo, revertTo) in [(false, true), (true, false)] {
            let r = report([volume("System", role: 1, oid: 1, live: 4_700_000, snapshots: [snap("orig-fs", tidemark: 7_200_000, rootTo: rootTo, revertTo: revertTo)])])
            XCTAssertFalse(SystemSnapshots.state(mounted: ["orig-fs"], report: r, minimumBytes: minimum).removable)
        }
    }

    func testAmbiguousVolumesAreNeverRemovable() {
        let r = report([volume("A", role: 0, oid: 1, live: 1, snapshots: [snap("orig-fs", tidemark: 2)]),
                        volume("B", role: 0, oid: 2, live: 1, snapshots: [snap("orig-fs", tidemark: 2)])])
        XCTAssertFalse(SystemSnapshots.state(mounted: ["orig-fs"], report: r, minimumBytes: minimum).removable)
    }

    func testHeldWhenTheSnapshotSetsTheLimit() throws {
        // orig-fs reaches block 7.2 M (29.5 GB), everything else block 4.7 M (19.3 GB).
        let r = report([volume("System", role: 1, oid: 1, live: 4_700_000, snapshots: [snap("orig-fs", tidemark: 7_200_000)]),
                        volume("Data", role: 0x40, oid: 2, live: 4_600_000, snapshots: [])])
        let state = SystemSnapshots.state(mounted: ["orig-fs"], report: r, minimumBytes: minimum)
        XCTAssertTrue(state.removable)
        let held = try XCTUnwrap(state.heldBytes)
        let without = APFSSnapshotReport.estimateMinimumBytes(tidemarkBlocks: 4_700_000, totalBlocks: blockCount, blockSize: 4096, maxFileSystems: 100)
        XCTAssertEqual(held, minimum - without)
        XCTAssertGreaterThan(held, 9_000_000_000)
    }

    func testNothingHeldWhenSomethingElseSetsTheLimit() {
        let r = report([volume("System", role: 1, oid: 1, live: 7_300_000, snapshots: [snap("orig-fs", tidemark: 7_200_000)])])
        XCTAssertEqual(SystemSnapshots.state(mounted: ["orig-fs"], report: r, minimumBytes: minimum).heldBytes, 0)
    }

    func testUnknownAmountWhenTheParseWasIncomplete() {
        let r = report([volume("System", role: 1, oid: 1, live: 4_700_000, snapshots: [snap("orig-fs", tidemark: 7_200_000, note: "failed to walk")])])
        let state = SystemSnapshots.state(mounted: ["orig-fs"], report: r, minimumBytes: minimum)
        XCTAssertTrue(state.removable)
        XCTAssertNil(state.heldBytes)
    }
}
