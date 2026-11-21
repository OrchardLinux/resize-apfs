import XCTest
import Foundation
@testable import ResizeCore
import ResizeDevice

final class CLIRunnerTests: XCTestCase {
    func testParseTargetBytesUnits() throws {
        XCTAssertEqual(try CLIRunner.parseTargetBytes("10"), 10 * 1_073_741_824)
        XCTAssertEqual(try CLIRunner.parseTargetBytes("10GiB"), 10 * 1_073_741_824)
        XCTAssertEqual(try CLIRunner.parseTargetBytes("10.5"), Int64(10.5 * 1_073_741_824))
        XCTAssertEqual(try CLIRunner.parseTargetBytes("10GB"), 10_000_000_000)
        XCTAssertEqual(try CLIRunner.parseTargetBytes("32MiB"), 32 * 1_048_576)
        XCTAssertEqual(try CLIRunner.parseTargetBytes("16777216B"), 16_777_216)
        XCTAssertThrowsError(try CLIRunner.parseTargetBytes(""))
        XCTAssertThrowsError(try CLIRunner.parseTargetBytes("0"))
        XCTAssertThrowsError(try CLIRunner.parseTargetBytes("-5"))
        XCTAssertThrowsError(try CLIRunner.parseTargetBytes("abc"))
    }

    func testCLIDryRunRefusesUnknownPartitionByDefaultAndExecutesGPTShrinkWhenAllowed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raf-cli-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DiskFixture(directory: directory)
        let state = directory.appendingPathComponent("state")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/debug/resize-helper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))

        // Fixture has a preceding EFI (.other) partition and APFS container (32 MiB) inside a 48 MiB backing partition.
        // Without --allow-other-partitions, CLI must refuse unknown partitions.
        XCTAssertThrowsError(try CLIRunner.run(
            arguments: [helper.path, "--fixture", fixture.url.path, "--sector-size", "4096",
                        "--state-dir", state.path, "--min-free-mib", "1", "--shrink-to", "32MiB"],
            executable: helper.path
        ))

        // Refuses growth under --shrink-to.
        XCTAssertThrowsError(try CLIRunner.run(
            arguments: [helper.path, "--fixture", fixture.url.path, "--sector-size", "4096",
                        "--state-dir", state.path, "--allow-other-partitions", "--min-free-mib", "1",
                        "--shrink-to", "40MiB"],
            executable: helper.path
        ))

        // Dry-run succeeds without modifying disk or writing operation.json.
        let before = try DeviceInspector.inspect(fixture.source)
        try CLIRunner.run(
            arguments: [helper.path, "--fixture", fixture.url.path, "--sector-size", "4096",
                        "--state-dir", state.path, "--allow-other-partitions", "--min-free-mib", "1",
                        "--shrink-to", "32MiB"],
            executable: helper.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("operation.json").path))
        XCTAssertEqual(try DeviceInspector.inspect(fixture.source).gpt, before.gpt)

        // Execute with --yes shrinks the backing GPT partition via the gated worker and leaves unallocated trailing space.
        try CLIRunner.run(
            arguments: [helper.path, "--fixture", fixture.url.path, "--sector-size", "4096",
                        "--state-dir", state.path, "--allow-other-partitions", "--min-free-mib", "1",
                        "--shrink-to", "32MiB", "--yes"],
            executable: helper.path
        )
        let after = try DeviceInspector.inspect(fixture.source)
        XCTAssertEqual(after.layout.backingBytes, fixture.containerBytes)
        XCTAssertEqual(after.layout.containerBytes, fixture.containerBytes)
        XCTAssertEqual(after.gpt.mbr, before.gpt.mbr)
        XCTAssertFalse(after.layout.partitions.contains { $0.kind == .linux })
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("operation.json").path))
    }

    func testRuntimeEnvironmentDetectsFixture() {
        let env = RuntimeEnvironment.detect(isFixture: true)
        XCTAssertEqual(env.kind, .fixture)
        XCTAssertTrue(env.prefersCLI)
    }

    func testSnapshotReportEstimateMatchesIOS12KernelFormula() {
        // Real iPod touch 6 32 GB container: 7,812,489 x 4096 B blocks, 512-block alignment.
        XCTAssertEqual(APFSSnapshotReport.alignmentBlocksFor(totalBlocks: 7_812_489, blockSize: 4096), 512)
        // Tidemark in 7,720,141..7,720,652 with default max_fs=60 yields exactly 31,771,852,800 B (7,756,800 blocks).
        XCTAssertEqual(
            APFSSnapshotReport.estimateMinimumBytes(tidemarkBlocks: 7_720_200, totalBlocks: 7_812_489,
                                                    blockSize: 4096, maxFileSystems: 60),
            31_771_852_800
        )
    }

    func testSnapshotOptionParsingAndReadOnlyLayoutIssueCleared() throws {
        let opts1 = try CLIRunner.parseOptions(["helper", "--snapshot-report", "--json"])
        XCTAssertEqual(opts1.action, .snapshotReport)
        XCTAssertTrue(opts1.jsonOutput)
        XCTAssertTrue(CLIRunner.hasCLIFlags(["helper", "--snapshot-report"]))

        let opts2 = try CLIRunner.parseOptions(["helper", "--delete-snapshot", "orig-fs", "--volume", "/"])
        XCTAssertEqual(opts2.action, .deleteSnapshot("orig-fs"))
        XCTAssertEqual(opts2.volumeMount, "/")
        XCTAssertFalse(opts2.confirmYes)

        let opts3 = try CLIRunner.parseOptions(["helper", "--create-snapshot", "orig-fs", "--yes"])
        XCTAssertEqual(opts3.action, .createSnapshot("orig-fs"))
        XCTAssertTrue(opts3.confirmYes)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raf-cli-snap-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DiskFixture(directory: directory)
        let readOnlySource = DeviceSource(path: fixture.url.path, fixtureSectorSize: 4096, writesEnabled: false)
        let inspected = try DeviceInspector.inspect(readOnlySource, queryMinimum: false,
                                                    allowReadOnlyMinimum: false,
                                                    readOnlyOverlayIssue: false)
        XCTAssertNil(inspected.layout.issue)
    }

    func testOnDiskAPFSSnapshotReportParsesTidemarkAndOmap() throws {
        // Construct a minimal checksummed synthetic APFS container with:
        //  block 0: NXSB (blockSize=4096, blockCount=256, xp_desc_base=1, xp_desc_blocks=2, nx_omap_oid=4, nx_fs_oid[0]=1026)
        //  block 1: NXSB checkpoint copy (xid=50)
        //  block 2: checkpoint map (xid=50, final flag set)
        //  block 4: container omap_phys_t (om_tree_oid=5)
        //  block 5: container omap B-tree leaf (oid=1026, xid=50 -> paddr=6)
        //  block 6: APSB volume "System" (role=1, volOmap=7, liveExt=9, snapMeta=10, numSnaps=1, rootTo=0, revertTo=0)
        //  block 7: volume omap_phys_t (om_tree_oid=8, om_most_recent_snap=40)
        //  block 8: volume omap B-tree leaf (oid=2000 xid=40 -> paddr=180; oid=2001 xid=50 -> paddr=90)
        //  block 9: live extentref_tree leaf (paddr=50 len=10 -> 50..59)
        //  block 10: snap_meta_tree leaf (snap_xid=40, name="orig-fs", extentref_tree_oid=11)
        //  block 11: snapshot extentref_tree leaf (paddr=12 len=4, paddr=220 len=15 -> max block 234)
        let bs = 4096
        let totalBlocks = 256
        var image = Data(count: totalBlocks * bs)

        func put16(_ d: inout Data, _ v: UInt16, at off: Int) {
            d[off] = UInt8(truncatingIfNeeded: v)
            d[off + 1] = UInt8(truncatingIfNeeded: v >> 8)
        }
        func signBlock(_ block: inout Data) {
            let modulus: UInt64 = 0xffff_ffff
            var a: UInt64 = 0, b: UInt64 = 0
            for off in stride(from: 8, to: block.count, by: 4) {
                a = (a + UInt64(block.le32(off))) % modulus
                b = (b + a) % modulus
            }
            let low = (modulus - ((a + b) % modulus)) % modulus
            let high = (modulus - ((a + low) % modulus)) % modulus
            block.put64((high << 32) | low, at: 0)
        }
        func writeBlock(_ index: Int, _ block: Data) {
            image.replaceSubrange((index * bs)..<((index + 1) * bs), with: block)
        }
        func makeLeafNode(oid: UInt64, xid: UInt64, fixedKV: (Int, Int)?, records: [(Data, Data)]) -> Data {
            var b = Data(count: bs)
            b.put64(oid, at: 8); b.put64(xid, at: 16); b.put32(0x4000_0002, at: 24)
            let flags: UInt16 = 0x0001 | 0x0002 | (fixedKV != nil ? 0x0004 : 0) // ROOT | LEAF [| FIXED_KV]
            put16(&b, flags, at: 32)
            put16(&b, 0, at: 34) // level 0
            b.put32(UInt32(records.count), at: 36)
            let tocEntrySize = fixedKV != nil ? 4 : 8
            let tocLen = records.count * tocEntrySize
            put16(&b, 0, at: 40) // toc off
            put16(&b, UInt16(tocLen), at: 42)
            let tocBase = 56
            let keyBase = tocBase + tocLen
            let valEnd = bs - 40
            if let (ks, vs) = fixedKV {
                b.put32(UInt32(bs), at: valEnd + 4)
                b.put32(UInt32(ks), at: valEnd + 8)
                b.put32(UInt32(vs), at: valEnd + 12)
            }
            var kCursor = 0
            var vCursor = 0
            for (idx, (k, v)) in records.enumerated() {
                vCursor += v.count
                if fixedKV != nil {
                    put16(&b, UInt16(kCursor), at: tocBase + idx * 4)
                    put16(&b, UInt16(vCursor), at: tocBase + idx * 4 + 2)
                } else {
                    put16(&b, UInt16(kCursor), at: tocBase + idx * 8)
                    put16(&b, UInt16(k.count), at: tocBase + idx * 8 + 2)
                    put16(&b, UInt16(vCursor), at: tocBase + idx * 8 + 4)
                    put16(&b, UInt16(v.count), at: tocBase + idx * 8 + 6)
                }
                b.replaceSubrange((keyBase + kCursor)..<(keyBase + kCursor + k.count), with: k)
                b.replaceSubrange((valEnd - vCursor)..<(valEnd - vCursor + v.count), with: v)
                kCursor += k.count
            }
            signBlock(&b)
            return b
        }

        // NXSB (blocks 0 and 1)
        var nxsb = Data(count: bs)
        nxsb.put64(1, at: 8); nxsb.put64(50, at: 16); nxsb.put32(0x8000_0001, at: 24)
        nxsb.replaceSubrange(32..<36, with: Data("NXSB".utf8))
        nxsb.put32(UInt32(bs), at: 36)
        nxsb.put64(UInt64(totalBlocks), at: 40)
        nxsb.put32(2, at: 104) // xp_desc_blocks
        nxsb.put64(1, at: 112) // xp_desc_base
        nxsb.put64(3, at: 152) // spaceman oid
        nxsb.put64(4, at: 160) // nx_omap_oid
        nxsb.put32(4, at: 180) // nx_max_file_systems
        nxsb.put64(1026, at: 184) // nx_fs_oid[0]
        signBlock(&nxsb)
        writeBlock(0, nxsb); writeBlock(1, nxsb)

        // Checkpoint map (block 2)
        var cpm = Data(count: bs)
        cpm.put64(2, at: 8); cpm.put64(50, at: 16); cpm.put32(0x4000_000c, at: 24)
        cpm.put32(1, at: 32) // CPM_LAST
        cpm.put32(0, at: 36) // 0 entries sufficient for snapshot report checkpoint check
        signBlock(&cpm)
        writeBlock(2, cpm)

        // Container omap (block 4) & tree leaf (block 5)
        var nxOmap = Data(count: bs)
        nxOmap.put64(4, at: 8); nxOmap.put64(50, at: 16); nxOmap.put32(0x4000_000b, at: 24)
        nxOmap.put64(5, at: 48) // om_tree_oid
        signBlock(&nxOmap)
        writeBlock(4, nxOmap)

        var ok = Data(count: 16); ok.put64(1026, at: 0); ok.put64(50, at: 8)
        var ov = Data(count: 16); ov.put32(0, at: 0); ov.put32(UInt32(bs), at: 4); ov.put64(6, at: 8)
        writeBlock(5, makeLeafNode(oid: 5, xid: 50, fixedKV: (16, 16), records: [(ok, ov)]))

        // APSB (block 6)
        var apsb = Data(count: bs)
        apsb.put64(1026, at: 8); apsb.put64(50, at: 16); apsb.put32(0x0000_000d, at: 24)
        apsb.replaceSubrange(32..<36, with: Data("APSB".utf8))
        apsb.put64(120, at: 88) // apfs_fs_alloc_count
        apsb.put32(0x4000_0002, at: 120) // extentref_tree_type (physical)
        apsb.put32(0x4000_0002, at: 124) // snap_meta_tree_type (physical)
        apsb.put64(7, at: 128) // apfs_omap_oid
        apsb.put64(9, at: 144) // apfs_extentref_tree_oid
        apsb.put64(10, at: 152) // apfs_snap_meta_tree_oid
        apsb.put64(0, at: 160) // apfs_revert_to_xid
        apsb.put64(1, at: 216) // apfs_num_snapshots
        let volNameBytes = Data("System\0".utf8)
        apsb.replaceSubrange(704..<(704 + volNameBytes.count), with: volNameBytes)
        put16(&apsb, 0x0001, at: 964) // APFS_VOL_ROLE_SYSTEM
        apsb.put64(0, at: 968) // apfs_root_to_xid
        signBlock(&apsb)
        writeBlock(6, apsb)

        // Volume omap (block 7) & leaf (block 8)
        var volOmap = Data(count: bs)
        volOmap.put64(7, at: 8); volOmap.put64(50, at: 16); volOmap.put32(0x4000_000b, at: 24)
        volOmap.put64(8, at: 48) // om_tree_oid
        volOmap.put64(40, at: 64) // om_most_recent_snap
        signBlock(&volOmap)
        writeBlock(7, volOmap)

        var vok1 = Data(count: 16); vok1.put64(2000, at: 0); vok1.put64(40, at: 8)
        var vov1 = Data(count: 16); vov1.put32(0, at: 0); vov1.put32(UInt32(bs), at: 4); vov1.put64(180, at: 8)
        var vok2 = Data(count: 16); vok2.put64(2001, at: 0); vok2.put64(50, at: 8)
        var vov2 = Data(count: 16); vov2.put32(0, at: 0); vov2.put32(UInt32(bs), at: 4); vov2.put64(90, at: 8)
        writeBlock(8, makeLeafNode(oid: 8, xid: 50, fixedKV: (16, 16), records: [(vok1, vov1), (vok2, vov2)]))

        // Live extentref_tree (block 9): blocks 50..59
        var lek = Data(count: 8); lek.put64((8 << 60) | 50, at: 0)
        var lev = Data(count: 20); lev.put64(10, at: 0)
        writeBlock(9, makeLeafNode(oid: 9, xid: 50, fixedKV: nil, records: [(lek, lev)]))

        // snap_meta_tree (block 10): snapshot "orig-fs" at xid=40 -> extentref_tree_oid=11
        var smk = Data(count: 8); smk.put64((1 << 60) | 40, at: 0)
        let snapName = Data("orig-fs\0".utf8)
        var smv = Data(count: 50 + snapName.count)
        smv.put64(11, at: 0) // extentref_tree_oid
        smv.put64(12, at: 8) // sblock_oid
        smv.put32(0x4000_0002, at: 40) // extentref_tree_type
        smv.put32(0, at: 44) // flags
        put16(&smv, UInt16(snapName.count), at: 48)
        smv.replaceSubrange(50..<(50 + snapName.count), with: snapName)
        writeBlock(10, makeLeafNode(oid: 10, xid: 50, fixedKV: nil, records: [(smk, smv)]))

        // Snapshot extentref_tree (block 11): extents 12..15 and 220..234
        var sek1 = Data(count: 8); sek1.put64((8 << 60) | 12, at: 0)
        var sev1 = Data(count: 20); sev1.put64(4, at: 0)
        var sek2 = Data(count: 8); sek2.put64((8 << 60) | 220, at: 0)
        var sev2 = Data(count: 20); sev2.put64(15, at: 0)
        writeBlock(11, makeLeafNode(oid: 11, xid: 40, fixedKV: nil, records: [(sek1, sev1), (sek2, sev2)]))

        let report = try APFSSnapshotReport.capture(partitionBytes: Int64(image.count)) { offset, length in
            Data(image[Int(offset)..<(Int(offset) + length)])
        }
        XCTAssertEqual(report.volumes.count, 1)
        let vol = report.volumes[0]
        XCTAssertEqual(vol.name, "System")
        XCTAssertEqual(vol.roleName, "System")
        XCTAssertEqual(vol.rootToXID, 0)
        XCTAssertEqual(vol.revertToXID, 0)
        XCTAssertEqual(vol.liveExtentMinBlock, 50)
        XCTAssertEqual(vol.liveExtentMaxBlock, 59)
        XCTAssertEqual(vol.snapshotOmapMaxBlock, 180)
        XCTAssertEqual(vol.liveOmapMaxBlock, 90)
        XCTAssertEqual(vol.snapshots.count, 1)
        let snap = vol.snapshots[0]
        XCTAssertEqual(snap.name, "orig-fs")
        XCTAssertEqual(snap.xid, 40)
        XCTAssertEqual(snap.extentMinBlock, 12)
        XCTAssertEqual(snap.extentMaxBlock, 234)
        XCTAssertEqual(snap.treeNodeMaxBlock, 11)
        XCTAssertEqual(snap.effectiveTidemarkBlock, 234)
        XCTAssertEqual(report.maxSnapshotTidemarkBlock, 234)
        XCTAssertEqual(report.pinningVolume, "System")
        XCTAssertEqual(report.pinningSnapshot, "orig-fs")
    }
}
