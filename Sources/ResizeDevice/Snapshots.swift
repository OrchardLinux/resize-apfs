import Foundation
import Darwin
import ResizeCore
import NativeSystem

/// checkra1n's system snapshot ("orig-fs", iOS 12-14): whether it exists, whether
/// it may be removed, and how much it raises APFS's minimum size.
public enum SystemSnapshots {
    public static let name = "orig-fs"
    public static let mount = "/"

    /// Only iOS 12-14 on a real disk: iOS 15 and later boot from a sealed system
    /// snapshot, which is never offered; fixtures and the Mac never have one.
    public static var applicable: Bool {
        #if os(iOS)
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15
        #else
        return false
        #endif
    }

    /// The snapshots the mounted system volume lists, or nil when listing fails.
    public static func mounted() -> [String]? {
        var buffer = [CChar](repeating: 0, count: 16384)
        guard raf_list_snapshots(mount, &buffer, buffer.count) == 0 else { return nil }
        let names = String(cString: buffer)
        return names.isEmpty ? [] : names.split(separator: "\n").map(String.init)
    }

    /// Combines the mounted volume's list with the on-disk metadata. Removable only
    /// when both agree it exists on exactly one system volume and neither the
    /// volume's boot (root_to) nor revert (revert_to) marker points at it.
    /// `minimumBytes` is iOS's own minimum query with the snapshot in place;
    /// `allocatedBytes` what the container uses in all.
    public static func state(mounted: [String], report: APFSSnapshotReport?, minimumBytes: Int64?,
                             allocatedBytes: Int64? = nil) -> SystemSnapshot {
        guard mounted.contains(name) else { return SystemSnapshot(name: name, present: false, removable: false) }
        guard let report else { return SystemSnapshot(name: name, present: true, removable: false) }
        let holders = report.volumes.filter { volume in volume.snapshots.contains { $0.name == name } }
        let system = holders.filter { $0.role == 0x0001 }
        guard let volume = system.count == 1 ? system[0] : (holders.count == 1 ? holders[0] : nil),
              let snapshot = volume.snapshots.first(where: { $0.name == name }) else {
            return SystemSnapshot(name: name, present: true, removable: false)
        }
        let removable = !snapshot.isRootTo && !snapshot.isRevertTo
        return SystemSnapshot(name: name, present: true, removable: removable,
                              heldBytes: heldBytes(by: snapshot, in: volume, report: report, minimumBytes: minimumBytes,
                                                   allocatedBytes: allocatedBytes))
    }

    /// iOS's minimum minus the minimum without this snapshot; 0 when it is not
    /// the one that sets the limit; nil when the inputs are incomplete.
    ///
    /// Without it, the limit is the highest block any other snapshot keeps (a
    /// snapshot's blocks stay where they are) and at least what the container
    /// uses (`allocatedBytes`), packed from the start: a shrink moves live data
    /// down, so the highest live block is no limit. Counting it was the error
    /// that put orig-fs at 0.1 GB on a J86 where removing it lowered iOS's
    /// minimum from 31.75 to 17.34 GB (resize-apfs#11). Without
    /// `allocatedBytes`, the highest live block stands in for it.
    static func heldBytes(by snapshot: APFSSnapshotReport.SnapshotDetail, in volume: APFSSnapshotReport.VolumeDetail,
                          report: APFSSnapshotReport, minimumBytes: Int64?, allocatedBytes: Int64? = nil) -> Int64? {
        guard let minimumBytes, snapshot.parseNote == nil, report.blockSize > 0 else { return nil }
        var snapshots: [UInt64] = [], live: [UInt64] = []
        for candidate in report.volumes {
            guard candidate.parseNote == nil else { return nil }
            live += [candidate.liveExtentMaxBlock, candidate.liveOmapMaxBlock].compactMap { $0 }
            snapshots += candidate.snapshots.filter { !(candidate.fsOID == volume.fsOID && $0.name == snapshot.name) }.map(\.effectiveTidemarkBlock)
        }
        let used: UInt64? = allocatedBytes.map { UInt64(max(0, $0) / report.blockSize) } ?? live.max()
        guard let rest = (snapshots + [used ?? 0]).max(), rest > 0 else { return nil }
        guard snapshot.effectiveTidemarkBlock > rest else { return 0 }
        let without = APFSSnapshotReport.estimateMinimumBytes(tidemarkBlocks: Int64(rest), totalBlocks: report.blockCount,
                                                             blockSize: report.blockSize, maxFileSystems: report.maxFileSystems)
        return max(0, minimumBytes - without)
    }

    /// The on-disk report for the container in `inspection`'s APFS partition.
    public static func report(_ source: DeviceSource, _ inspection: DeviceInspection) throws -> APFSSnapshotReport {
        let disk = try RawDisk(source)
        let partition = inspection.layout.apfs
        let bytes = partition.blocks * disk.sectorSize
        return try APFSSnapshotReport.capture(partitionBytes: bytes) { offset, length in
            guard offset >= 0, offset <= bytes - Int64(length) else { throw ResizeError("APFS metadata exceeds its backing partition.") }
            return try disk.read(partition.firstLBA * disk.sectorSize + offset, length)
        }
    }

    /// Sets orig-fs's state and the list of every volume's snapshots on a fresh
    /// inspection; leaves both nil where there is nothing to manage.
    public static func fill(_ source: DeviceSource, _ inspection: inout DeviceInspection) {
        inspection.layout.systemSnapshot = nil
        inspection.layout.snapshotVolumes = nil
        guard applicable, !source.isFixture, let names = mounted() else { return }
        let report = try? report(source, inspection)
        let minimum = inspection.layout.minimumContainerBytes, used = inspection.layout.allocatedBytes
        inspection.layout.systemSnapshot = state(mounted: names, report: report, minimumBytes: minimum, allocatedBytes: used)
        inspection.layout.snapshotVolumes = report.map { volumes($0, minimumBytes: minimum, allocatedBytes: used) }
    }

    /// Every volume and its snapshots, for Technical details.
    public static func volumes(_ report: APFSSnapshotReport, minimumBytes: Int64?, allocatedBytes: Int64? = nil) -> [SnapshotVolume] {
        report.volumes.map { volume in
            SnapshotVolume(volume: volume.name, role: volume.roleName, snapshots: volume.snapshots.map { snapshot in
                SnapshotVolume.Entry(name: snapshot.name, bootsFrom: snapshot.isRootTo, revertsTo: snapshot.isRevertTo,
                                     heldBytes: heldBytes(by: snapshot, in: volume, report: report, minimumBytes: minimumBytes,
                                                          allocatedBytes: allocatedBytes))
            })
        }
    }
}
