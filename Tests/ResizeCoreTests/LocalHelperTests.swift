import XCTest
import Foundation
@testable import ResizeCore
import ResizeDevice

final class LocalHelperTests: XCTestCase {
    func testRealSocketWorkerJournalAndGPTWriterUsingOnlyFileFixture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raf-" + UUID().uuidString.prefix(8))
        let fixture = try DiskFixture(directory: directory)
        let ipc = directory.appendingPathComponent("ipc")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/debug/resize-helper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--fixture", fixture.url.path, "--sector-size", "4096", "--allow-writes",
                             "--state-dir", directory.appendingPathComponent("state").path, "--ipc-dir", ipc.path]
        let log = directory.appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output; process.standardError = output
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? output.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let service = LocalSocketResizeService(directory: ipc)
        var first: ServiceSnapshot?
        for _ in 0..<40 {
            if let value = try? await service.snapshot() { first = value; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let snapshot = try XCTUnwrap(first, "The real helper did not publish its fixture inspection.")
        XCTAssertEqual(snapshot.mode, "fixture")
        // Existing status traffic must not resolve the filesystem socket path
        // again. Simulate an unavailable pathname after connecting, without
        // freezing or modifying a real filesystem.
        let movedIPC = directory.appendingPathComponent("ipc-moved")
        try FileManager.default.moveItem(at: ipc, to: movedIPC)
        do {
            let stillConnected = try await service.snapshot()
            XCTAssertEqual(stillConnected.layout.diskID, snapshot.layout.diskID)
        } catch {
            try? FileManager.default.moveItem(at: movedIPC, to: ipc)
            throw error
        }
        try FileManager.default.moveItem(at: movedIPC, to: ipc)
        let plan = try await service.plan(PlanRequest(revision: snapshot.layout.revision,
                                                     requestedBytes: fixture.containerBytes, createLinux: true))
        let start = StartRequest(planID: plan.id, requestID: UUID())
        let accepted = try await service.start(start)
        let duplicate = try await service.start(start)
        XCTAssertEqual(accepted.operation?.id, duplicate.operation?.id)
        // A different client instance reconnects to the same independent helper.
        let reconnected = LocalSocketResizeService(directory: ipc)
        var latest = accepted
        for _ in 0..<80 {
            latest = try await reconnected.snapshot()
            if latest.operation?.status != .running { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertEqual(latest.operation?.id, accepted.operation?.id)
        XCTAssertEqual(latest.operation?.status, .completed, latest.operation?.message ?? "No completion")
        XCTAssertEqual(latest.layout.backingBytes, fixture.containerBytes)
        XCTAssertTrue(latest.layout.partitions.contains { $0.kind == .linux })
        let after = try DeviceInspector.inspect(fixture.source)
        XCTAssertEqual(after.layout.containerBytes, fixture.containerBytes)
        XCTAssertEqual(after.layout.backingBytes, fixture.containerBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state/operation.json").path))
    }
}
