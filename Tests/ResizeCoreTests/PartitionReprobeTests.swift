import XCTest
import Foundation
import ResizeDevice

final class PartitionReprobeTests: XCTestCase {
    /// A fake kernel: the partition shows `grown` bytes `delay` seconds after an accepted probe.
    private func system(result: Int32 = 0, scheme: Int32 = 0, delay: TimeInterval? = 1, old: UInt64 = 100, grown: UInt64 = 200,
                        probes: UnsafeMutablePointer<Int>? = nil) -> (PartitionReprobe.System, () -> TimeInterval) {
        var clock: TimeInterval = 0
        var probedAt: TimeInterval?
        let system = PartitionReprobe.System(
            probe: { probes?.pointee += 1; probedAt = clock; return (result, scheme, scheme == 0 ? -1 : 0x2c7) },
            capacity: {
                guard result == 0, let at = probedAt, let delay, clock >= at + delay else { return old }
                return grown
            },
            now: { clock },
            sleep: { clock += $0 })
        return (system, { clock })
    }

    func testTheGrowFindsTheNewSizeOnceTheKernelHasReadTheTable() {
        let (fake, clock) = system()
        let outcome = PartitionReprobe.run(target: 200, using: fake)
        XCTAssertTrue(outcome.reached)
        XCTAssertEqual(outcome.before, 100)
        XCTAssertEqual(outcome.after, 200)
        XCTAssertLessThan(clock(), 2)
    }

    func testASizeThatDoesNotChangeIsWaitedForOnlyUntilTheDeadline() {
        let (fake, clock) = system(delay: nil)
        let outcome = PartitionReprobe.run(target: 200, using: fake)
        XCTAssertFalse(outcome.reached)
        XCTAssertEqual(outcome.after, 100)
        XCTAssertGreaterThanOrEqual(clock(), PartitionReprobe.deadline)
        XCTAssertLessThan(clock(), PartitionReprobe.deadline + 1)
    }

    func testARefusedProbeIsNotWaitedFor() {
        var probes = 0
        let (fake, clock) = system(result: EIO, scheme: Int32(bitPattern: 0xe00002c7), probes: &probes)
        let outcome = PartitionReprobe.run(target: 200, using: fake)
        XCTAssertFalse(outcome.reached)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(clock(), 0)
        let line = PartitionReprobe.describe(outcome, whole: "disk0", partition: "disk0s1", target: 200)
        XCTAssertTrue(line.contains("partition scheme probe 0xe00002c7"), line)
        XCTAssertTrue(line.contains("100 bytes before, 100 after, target 200"), line)
        XCTAssertTrue(line.hasSuffix("iOS still exposes the old size."), line)
    }

    func testWithoutATargetAnyChangeCounts() {
        let (fake, _) = system(grown: 150)
        XCTAssertTrue(PartitionReprobe.run(target: nil, using: fake).reached)
        let (unchanged, _) = system(delay: nil)
        XCTAssertFalse(PartitionReprobe.run(target: nil, using: unchanged).reached)
    }

    func testOnlyPartitionDeviceNamesAreProbed() {
        XCTAssertEqual(PartitionReprobe.wholeDisk(of: "disk0s1"), "disk0")
        XCTAssertEqual(PartitionReprobe.wholeDisk(of: "disk12s3"), "disk12")
        for name in ["disk0", "disk0s", "disks1", "disk0s1s1", "/dev/disk0s1", "rdisk0s1", "disk0s1x"] {
            XCTAssertNil(PartitionReprobe.wholeDisk(of: name), name)
        }
    }

    func testOutcomesAreKeptInTheJournalFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        PartitionReprobe.record("first", in: directory)
        PartitionReprobe.record("second", in: directory)
        let text = try String(contentsOf: directory.appendingPathComponent("reprobe.log"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.contains(" first\n") && text.hasSuffix(" second\n"), text)
    }
}
