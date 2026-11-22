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
}
