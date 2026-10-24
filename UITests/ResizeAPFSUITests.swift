import XCTest

final class ResizeAPFSUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func reset(_ scenario: String, scale: Double = 0.15) throws {
        let done = expectation(description: "Reset independent mock service")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8472/admin/scenario")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scenario": scenario, "timeScale": scale, "discardSimulation": true])
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
    }

    private func snapshotJSON() throws -> [String: Any] {
        let done = expectation(description: "Read independent service state")
        var result: [String: Any] = [:]
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:8472/snapshot")!) { data, _, error in
            XCTAssertNil(error)
            if let data { result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }

    private func openEditor(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["adjustSize"].waitForExistence(timeout: 15))
        app.buttons["adjustSize"].coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        XCTAssertTrue(app.textFields["targetSize"].waitForExistence(timeout: 5))
    }

    private func enterSize(_ value: String, app: XCUIApplication) {
        let field = app.textFields["targetSize"]
        field.tap()
        app.buttons["targetSizeClear"].tap()
        field.typeText(value)
        if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
    }

    private func apply(_ app: XCUIApplication) {
        app.buttons["reviewChanges"].coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["applyChanges"].waitForExistence(timeout: 5))
        app.buttons["applyChanges"].coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.firstMatch.buttons.matching(identifier: "confirmStart").firstMatch.tap()
    }

    func testShrinkCreateLinuxAndReopenWhileRunning() throws {
        try reset("normal", scale: 1.5)
        let app = XCUIApplication()
        openEditor(app)
        enterSize("24", app: app)
        app.swipeUp()
        XCTAssertTrue(app.buttons["createLinux"].waitForExistence(timeout: 3))
        app.buttons["createLinux"].tap()
        apply(app)
        XCTAssertTrue(app.staticTexts["operationHeading"].waitForExistence(timeout: 5))
        let beforeReopen = try snapshotJSON()
        let operationID = (beforeReopen["operation"] as? [String: Any])?["id"] as? String
        XCTAssertNotNil(operationID)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["operationHeading"].waitForExistence(timeout: 8))
        let afterReopen = try snapshotJSON()
        XCTAssertEqual((afterReopen["operation"] as? [String: Any])?["id"] as? String, operationID)
        XCTAssertTrue(app.staticTexts["operationCompleted"].waitForExistence(timeout: 60))
        let result = try snapshotJSON()
        let partitions = (result["layout"] as? [String: Any])?["partitions"] as? [[String: Any]]
        XCTAssertTrue(partitions?.contains { $0["kind"] as? String == "linux" } == true)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Completed shrink with Linux partition"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["done"].tap()
        XCTAssertTrue(app.buttons["adjustSize"].waitForExistence(timeout: 5))
    }

    func testPartitionChoicesDisappearWhenNoSpaceRemains() throws {
        try reset("freeSpace")
        let app = XCUIApplication()
        openEditor(app)
        func setFree(_ value: String) {
            app.textFields["freeAfter"].tap()
            app.buttons["freeAfterClear"].tap()
            app.textFields["freeAfter"].typeText(value)
            if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
        }
        setFree("0.3")
        app.swipeUp()
        XCTAssertTrue(app.buttons["createLinux"].waitForExistence(timeout: 3))
        app.buttons["createLinux"].tap()
        app.swipeDown()
        setFree("0")
        XCTAssertFalse(app.buttons["createLinux"].exists)
        XCTAssertFalse(app.staticTexts["Space after APFS"].exists)
        app.buttons["reviewChanges"].tap()
        XCTAssertTrue(app.buttons["applyChanges"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Linux partition will be created. Any remaining space stays unallocated."].exists)
    }

    func testHeartbeatRemainsFreshDuringLongResize() throws {
        try reset("longSilence", scale: 0.4)
        let app = XCUIApplication()
        openEditor(app)
        enterSize("24", app: app)
        apply(app)
        let confirmed = app.staticTexts["workerLastConfirmed"]
        XCTAssertTrue(confirmed.waitForExistence(timeout: 8))
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 2)
            let label = confirmed.label
            let age = Int(label.split(separator: " ").first ?? "")
            XCTAssertNotNil(age, label)
            XCTAssertLessThanOrEqual(age ?? Int.max, 4, "UI heartbeat is stale despite live mock worker: \(label)")
        }
    }

    func testGrowIntoFreeSpace() throws {
        try reset("freeSpace")
        let app = XCUIApplication()
        openEditor(app)
        enterSize("28", app: app)
        apply(app)
        XCTAssertTrue(app.staticTexts["operationCompleted"].waitForExistence(timeout: 20))
    }

    func testPartitionFailureReturnsToInspectableState() throws {
        try reset("partitionError")
        let app = XCUIApplication()
        openEditor(app)
        enterSize("24", app: app)
        apply(app)
        XCTAssertTrue(app.staticTexts["operationStopped"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["backToStorage"].exists)
        app.buttons["backToStorage"].tap()
        XCTAssertTrue(app.buttons["adjustSize"].waitForExistence(timeout: 5))
    }
}
