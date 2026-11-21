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
}
