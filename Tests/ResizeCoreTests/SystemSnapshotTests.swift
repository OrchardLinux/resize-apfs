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

    /// The J86 of resize-apfs#11, measured: a 31,999,954,944-byte container,
    /// 16.6 GB in use, live data up to near its end, iOS's minimum 31,750,881,280
    /// bytes, and 17,339,252,736 after removing orig-fs, which therefore held
    /// 14.4 GB. Counting the highest live block put it at 0.1 GB.
    func testLiveDataNearTheEndIsNoLimitBecauseAShrinkMovesIt() throws {
        let blocks: Int64 = 31_999_954_944 / 4096
        let r = APFSSnapshotReport(containerID: UUID(), transactionID: 1, blockSize: 4096, blockCount: blocks, maxFileSystems: 100,
                                   alignmentBlocks: 256, maxSnapshotTidemarkBlock: 0, maxSnapshotTidemarkBytes: 0, estimatedSnapshotMinimumBytes: nil,
                                   pinningVolume: nil, pinningSnapshot: nil,
                                   volumes: [volume("System", role: 1, oid: 1, live: 7_700_000, snapshots: [snap("orig-fs", tidemark: 7_740_000)]),
                                             volume("Data", role: 0x40, oid: 2, live: 7_690_000, snapshots: [])])
        let state = SystemSnapshots.state(mounted: ["orig-fs"], report: r, minimumBytes: 31_750_881_280, allocatedBytes: 16_600_000_000)
        let held = try XCTUnwrap(state.heldBytes)
        // Measured 14.41 GB; the estimate packs what is used, so it errs high by
        // what iOS keeps beyond that (0.7 GB here), never toward 0.
        XCTAssertGreaterThan(held, 13_500_000_000)
        XCTAssertLessThan(held, 15_500_000_000)
        // Without what the container uses, the highest live block stands in, as before.
        XCTAssertLessThan(try XCTUnwrap(SystemSnapshots.state(mounted: ["orig-fs"], report: r, minimumBytes: 31_750_881_280).heldBytes),
                          1_000_000_000)
    }

    func testAnotherSnapshotFurtherOutSetsTheLimitWhateverIsInUse() {
        let r = report([volume("System", role: 1, oid: 1, live: 1_000_000, snapshots: [
                            snap("com.apple.os.update-1", tidemark: 7_300_000, rootTo: true), snap("orig-fs", tidemark: 7_200_000)])])
        XCTAssertEqual(SystemSnapshots.state(mounted: ["orig-fs"], report: r, minimumBytes: minimum, allocatedBytes: 4_000_000_000).heldBytes, 0)
    }

    /// Perry's case: orig-fs holds little, the booted update snapshot sets the limit.
    /// The list shows every volume's snapshots with their markers and held space.
    func testListShowsEverySnapshotWithMarkersAndHeldSpace() throws {
        let r = report([volume("System", role: 1, oid: 1, live: 4_700_000, snapshots: [
                            snap("com.apple.os.update-8F2A", tidemark: 7_200_000, rootTo: true),
                            snap("orig-fs", tidemark: 4_720_000)]),
                        volume("Data", role: 0, oid: 2, live: 4_600_000, snapshots: [])])
        let volumes = SystemSnapshots.volumes(r, minimumBytes: minimum)
        XCTAssertEqual(volumes.map(\.volume), ["System", "Data"])
        let update = volumes[0].snapshots[0], orig = volumes[0].snapshots[1]
        XCTAssertTrue(update.bootsFrom); XCTAssertFalse(update.revertsTo)
        XCTAssertGreaterThan(try XCTUnwrap(update.heldBytes), 9_000_000_000)
        XCTAssertEqual(orig.heldBytes, 0, "the update snapshot reaches further, so orig-fs sets no limit")
        XCTAssertTrue(volumes[1].snapshots.isEmpty)
        let text = SnapshotVolume.describe(volumes)
        XCTAssertTrue(text.contains("com.apple.os.update-8F2A  boots from  holds "), text)
        XCTAssertTrue(text.contains("orig-fs  -  holds 0 GB"), text)
        XCTAssertTrue(text.contains("Data  (none)"), text)
    }
}
