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
        // The app's own confirmation dialog: its buttons are found by their fixed titles.
        XCTAssertTrue(app.buttons["Start resize"].waitForExistence(timeout: 3))
        app.buttons["Start resize"].tap()
    }

    func testShrinkCreateLinuxAndReopenWhileRunning() throws {
        try reset("normal", scale: 1.5)
        let app = XCUIApplication()
        openEditor(app)
        // Sizes show rounded like everywhere else; the exact values stay behind them.
        XCTAssertEqual(app.textFields["targetSize"].value as? String, "31.6")
        XCTAssertEqual(app.textFields["freeAfter"].value as? String, "0")
        enterSize("24.56", app: app)
        XCTAssertEqual(app.textFields["targetSize"].value as? String, "24.5", "one decimal at most")
        enterSize("24", app: app)
        XCTAssertEqual(app.textFields["freeAfter"].value as? String, "7.6")
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
        // Stepwise shrinking made this run take about a minute; leave room.
        XCTAssertTrue(app.staticTexts["operationCompleted"].waitForExistence(timeout: 120))
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
        // No free space left: the plan grows APFS into all of it, without a Linux partition.
        XCTAssertTrue(app.staticTexts["APFS grows into the unallocated space after it."].exists)
        XCTAssertFalse(app.staticTexts["Linux · unformatted"].exists)
    }

    func testRemoveSnapshotFromTheEditorThenTakeANewOne() throws {
        try reset("snapshot")
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["removeSnapshot"].waitForExistence(timeout: 15), "the overview offers the removal")
        app.buttons["adjustSize"].coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        XCTAssertTrue(app.textFields["targetSize"].waitForExistence(timeout: 5))
        enterSize("24", app: app)
        XCTAssertTrue(app.staticTexts["sizeValidation"].waitForExistence(timeout: 3), "24 GB is below the minimum while orig-fs exists")
        XCTAssertFalse(app.buttons["reviewChanges"].isEnabled)
        app.buttons["removeSnapshot"].tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 3))
        app.buttons["Remove"].tap()
        // Still in the editor, same size, now allowed.
        let deadline = Date().addingTimeInterval(8)
        while app.staticTexts["sizeValidation"].exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertFalse(app.staticTexts["sizeValidation"].exists)
        XCTAssertEqual(app.textFields["targetSize"].value as? String, "24")
        XCTAssertFalse(app.buttons["removeSnapshot"].exists)
        XCTAssertFalse(app.staticTexts["serviceError"].exists, "the removal is the user's own change, not \"Storage changed\"")
        XCTAssertTrue(app.buttons["reviewChanges"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["takeSnapshot"].waitForExistence(timeout: 5))
        app.buttons["takeSnapshot"].tap()
        // The legend row reads out as one element: "Held by snapshot orig-fs".
        XCTAssertTrue(app.descendants(matching: .any)["Held by snapshot orig-fs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["takeSnapshot"].exists)
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
            // Under 10 seconds the age reads "now".
            let label = confirmed.label
            XCTAssertEqual(label, "now", "UI heartbeat is stale despite live mock worker: \(label)")
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

    /// The bar's boundary is the size slider: dragging it changes the size.
    func testDraggingTheBarChangesTheSize() throws {
        try reset("freeSpace")
        let app = XCUIApplication()
        openEditor(app)
        let slider = app.descendants(matching: .any)["sizeSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let field = app.textFields["targetSize"]
        let before = field.value as? String
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)))
        XCTAssertNotEqual(field.value as? String, before)
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
