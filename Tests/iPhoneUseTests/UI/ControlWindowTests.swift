import XCTest

@testable import iPhoneUse

final class ControlWindowStateTests: XCTestCase {
    func testStartupWaitsWithoutADeviceAndOpensEachConnectedPhoneOnce() {
        var state = ControlWindowState()
        XCTAssertEqual(state.update(connectedIDs: []), [])
        XCTAssertTrue(state.needsWaitingWindow)

        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"]), ["phone-a", "phone-b"])
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertEqual(state.update(connectedIDs: ["phone-b", "phone-a"]), [])
        XCTAssertEqual(state.deviceIDs, ["phone-a", "phone-b"])
    }

    func testDisconnectAndReconnectKeepTheSameWindowsWithoutRetargeting() {
        var state = ControlWindowState()
        _ = state.update(connectedIDs: ["phone-a", "phone-b"])

        XCTAssertEqual(state.update(connectedIDs: ["phone-b", "phone-c"]), ["phone-c"])
        XCTAssertEqual(state.deviceIDs, ["phone-a", "phone-b", "phone-c"])
        XCTAssertEqual(state.update(connectedIDs: []), [])
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertEqual(state.update(connectedIDs: ["phone-a"]), [])
    }

    func testClosingOneWindowKeepsOtherWindowsAndDoesNotReopenOnEveryRefresh() {
        var state = ControlWindowState()
        _ = state.update(connectedIDs: ["phone-a", "phone-b"])

        XCTAssertFalse(state.close(deviceID: "phone-a"))
        for _ in 0..<3 {
            XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"]), [])
        }
        XCTAssertEqual(state.deviceIDs, ["phone-b"])
        XCTAssertTrue(state.close(deviceID: "phone-b"))
    }

    func testShowAllReopensClosedWindowsWithoutDuplicatingExistingOnes() {
        var state = ControlWindowState()
        _ = state.update(connectedIDs: ["phone-a", "phone-b"])
        _ = state.close(deviceID: "phone-a")

        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"], reopenClosed: true), ["phone-a"])
        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"], reopenClosed: true), [])
        XCTAssertEqual(state.deviceIDs, ["phone-a", "phone-b"])
    }

    func testReconnectingAManuallyClosedDeviceOpensANewWindow() {
        var state = ControlWindowState()
        _ = state.update(connectedIDs: ["phone-a", "phone-b"])
        _ = state.close(deviceID: "phone-a")

        XCTAssertEqual(state.update(connectedIDs: ["phone-b"]), [])
        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"]), ["phone-a"])
    }

    func testClosingTheOnlyDisconnectedWindowOrStartupPlaceholderExits() {
        var state = ControlWindowState()
        XCTAssertTrue(state.close(deviceID: nil))
        _ = state.update(connectedIDs: ["phone-a"])
        _ = state.update(connectedIDs: [])
        XCTAssertTrue(state.close(deviceID: "phone-a"))
    }
}

final class MultiDeviceWindowInputTests: XCTestCase {
    func testCancellingOneWindowDragLeavesTheOtherDevicePressedAndBusy() throws {
        var firstReports: [[UInt8]] = []
        var secondReports: [[UInt8]] = []
        let first = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { _, bytes in firstReports.append(bytes) })
        let second = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { _, bytes in secondReports.append(bytes) })

        first.press(x: 0.25, y: 0.25)
        second.press(x: 0.75, y: 0.75)
        // These synchronous API calls drain each device queue before observing
        // its window drag. Both must reject a competing coordinate operation.
        XCTAssertThrowsError(try first.nudge(dx: 0, dy: 0, click: false))
        XCTAssertThrowsError(try second.nudge(dx: 0, dy: 0, click: false))
        let secondBeforeCancel = secondReports

        // Losing focus or closing the first window releases only that phone.
        first.cancelPointer()
        try first.nudge(dx: 0, dy: 0, click: false)
        XCTAssertEqual(firstReports.last, [0, 0, 32, 0, 32])
        XCTAssertThrowsError(try second.nudge(dx: 0, dy: 0, click: false))
        XCTAssertEqual(secondReports, secondBeforeCancel)
        XCTAssertEqual(secondReports.last?.first, 1)

        // Its API can resume while the second phone's window is still dragging.
        try first.tap(x: 0.5, y: 0.5)
        XCTAssertThrowsError(try second.nudge(dx: 0, dy: 0, click: false))
        XCTAssertEqual(secondReports, secondBeforeCancel)
        second.cancelPointer()
        try second.nudge(dx: 0, dy: 0, click: false)
        XCTAssertEqual(secondReports.last, [0, 255, 95, 255, 95])
    }
}
