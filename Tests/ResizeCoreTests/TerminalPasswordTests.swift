import XCTest
import ResizeDevice

final class TerminalPasswordTests: XCTestCase {
    /// The line the bootstraps in Dopamine 3.0.13 ship for the device's user: the password `alpine`.
    private let shipped = "mobile:$6$V7qMYJaNbVKOeh4P$iybXGZgLR3X57uggElv.cYndy9mDF0fKvu6NB57tb3Krbo/eE6/tP7.Vvf04JZ2Ni2/0x1Wwy0NaUrrEYZPpz0:501:501::0:0:Mobile User:/var/mobile:/bin/sh"

    func testTheShippedAccountFileHasTheDefault() {
        XCTAssertTrue(TerminalPassword.hasDefault("# comment\nroot:!:0:0::0:0:System Administrator:/var/root:/bin/sh\n\(shipped)\n"))
    }

    func testAPasswordTheUserChoseIsLeftAlone() {
        let chosen = shipped.replacingOccurrences(of: "iybXGZgL", with: "someOther")
        XCTAssertFalse(TerminalPassword.hasDefault("root:!:0:0::0:0:System Administrator:/var/root:/bin/sh\n\(chosen)\n"))
    }

    func testOnlyTheDevicesUserCounts() {
        // The same hash on another account is not ours to change.
        XCTAssertFalse(TerminalPassword.hasDefault(shipped.replacingOccurrences(of: ":501:501:", with: ":502:502:")))
        XCTAssertFalse(TerminalPassword.hasDefault(""))
    }
}
