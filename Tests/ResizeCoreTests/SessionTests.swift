import XCTest
import Foundation
@testable import ResizeCore
import ResizeDevice

final class SessionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raf-session-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUIPathMustBeProtectedRegularFile() throws {
        let app = try temporaryDirectory().appendingPathComponent("ResizeAPFS.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let binary = app.appendingPathComponent("ResizeAPFS")
        try Data([0]).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let resolved = binary.resolvingSymlinksInPath().path
        XCTAssertEqual(try SessionTrust.validatedUIPath(binary.path), resolved)
        XCTAssertThrowsError(try SessionTrust.validatedUIPath("relative/ResizeAPFS"))
        XCTAssertThrowsError(try SessionTrust.validatedUIPath(app.path), "a directory is not an executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: binary.path)
        XCTAssertThrowsError(try SessionTrust.validatedUIPath(binary.path), "others could replace the trusted executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: app.path)
        XCTAssertThrowsError(try SessionTrust.validatedUIPath(binary.path), "others could swap the file through its directory")
    }

    func testOnlyBundlesDirectlyInApplicationsAreRegistered() {
        for path in ["/Applications", "/Applications/Other/ResizeAPFS.app", "/Applications/../tmp/ResizeAPFS.app",
                     "/var/root/ResizeAPFS.app", "/Applications/ResizeAPFS", "Applications/ResizeAPFS.app"] {
            XCTAssertThrowsError(try AppRegistration.validate(path), path)
        }
        // Well-formed but absent on this Mac: refused for the missing bundle, not the path.
        XCTAssertThrowsError(try AppRegistration.validate("/Applications/ResizeAPFS-test-\(UUID().uuidString).app")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("not an app bundle directory"))
        }
    }

    func testOperationActiveWithoutJournalIsFalse() throws {
        XCTAssertFalse(DeviceEngine.operationActive(directory: try temporaryDirectory()))
    }

    /// A fake iOS for `AppQuit`: the app runs until FrontBoard (after `exitDelay`
    /// seconds) or a kill ends it; FrontBoard forgets it `frontBoardLag` later.
    private final class FakeDevice {
        var clock: TimeInterval = 0
        var running = true
        var endedAt: TimeInterval?
        var terminateHonoured = true
        var frontBoardAvailable = true
        var exitDelay: TimeInterval = 0.5
        var frontBoardLag: TimeInterval = 0.3
        var calls: [String] = []
        var terminatedAt: TimeInterval?
        func update() {
            if running, let at = terminatedAt, terminateHonoured, clock >= at + exitDelay { running = false; endedAt = clock }
        }
        var system: AppQuit.System {
            AppQuit.System(
                processRunning: { self.update(); return self.running ? 1 : 0 },
                frontBoardPID: {
                    guard self.frontBoardAvailable else { return nil }
                    self.update()
                    if self.running { return 42 }
                    return self.clock < self.endedAt! + self.frontBoardLag ? 42 : 0
                },
                terminate: { self.calls.append("terminate"); guard self.frontBoardAvailable else { return false }
                             self.terminatedAt = self.clock; return true },
                kill: { self.calls.append("kill"); if self.running { self.running = false; self.endedAt = self.clock } },
                now: { self.clock },
                sleep: { self.clock += $0 })
        }
    }

    func testQuitWaitsUntilFrontBoardNoLongerKnowsTheApp() throws {
        let device = FakeDevice()
        try AppQuit.quit("app", using: device.system)
        XCTAssertEqual(device.calls, ["terminate"])
        XCTAssertFalse(device.running)
        // Not done when the process ended, only once FrontBoard let go of it too.
        XCTAssertGreaterThanOrEqual(device.clock, device.endedAt! + device.frontBoardLag)
    }

    func testQuitOfAnAppThatDoesNotRunDoesNothing() throws {
        let device = FakeDevice()
        device.running = false; device.endedAt = -10
        try AppQuit.quit("app", using: device.system)
        XCTAssertEqual(device.calls, [])
    }

    func testAnIgnoredTerminationIsFollowedByAKillAfterTheDeadline() throws {
        let device = FakeDevice()
        device.terminateHonoured = false
        try AppQuit.quit("app", using: device.system)
        XCTAssertEqual(device.calls, ["terminate", "kill"])
        XCTAssertGreaterThanOrEqual(device.endedAt!, AppQuit.deadline)
    }

    func testWithoutFrontBoardTheProcessIsKilledAndWaitedFor() throws {
        let device = FakeDevice()
        device.frontBoardAvailable = false
        try AppQuit.quit("app", using: device.system)
        XCTAssertEqual(device.calls, ["terminate", "kill"])
        XCTAssertFalse(device.running)
    }

    func testAnAppThatCannotBeEndedIsNotRemoved() {
        let device = FakeDevice()
        device.terminateHonoured = false
        var system = device.system
        system.kill = { device.calls.append("kill") }
        XCTAssertThrowsError(try AppQuit.quit("app", using: system)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not removed"))
        }
        XCTAssertLessThanOrEqual(device.clock, 2 * AppQuit.deadline + 1)
    }

    func testTheHelperWaitsForTheFirstUnlockAndSaysSoOnce() {
        var answers: [Bool?] = [false, false, false, true]
        var logs: [String] = [], slept = 0
        FirstUnlock.wait(query: { answers.removeFirst() }, sleep: { _ in slept += 1 }, log: { logs.append($0) })
        XCTAssertTrue(answers.isEmpty)
        XCTAssertEqual(slept, 3)
        XCTAssertEqual(logs.count, 2)
    }

    func testAnUnlockedDeviceOrAnUnansweredQueryDoesNotWait() {
        for answer in [true, nil] as [Bool?] {
            var logs: [String] = []
            FirstUnlock.wait(query: { answer }, sleep: { _ in XCTFail("waited") }, log: { logs.append($0) })
            XCTAssertEqual(logs, [])
        }
    }
}
