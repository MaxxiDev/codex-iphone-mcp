import AppKit
import CoreGraphics
import XCTest

@testable import iPhoneUse

final class ControlKeyboardEventTests: XCTestCase {
    func testSpecialKeysSendKeyCommandsAndPreserveModifierOrder() {
        let keys: [(UInt16, String)] = [
            (0x24, "enter"), (0x4C, "enter"), (0x30, "tab"), (0x31, "space"),
            (0x33, "backspace"), (0x75, "forwarddelete"), (0x35, "escape"),
            (0x7B, "left"), (0x7C, "right"), (0x7D, "down"), (0x7E, "up"),
            (0x73, "home"), (0x77, "end"), (0x74, "pageup"), (0x79, "pagedown"),
        ]
        for (keyCode, key) in keys {
            let event = ControlKeyboardEvent(
                keyCode: keyCode, modifierFlags: [.control, .option, .shift, .command, .capsLock],
                characters: "ignored", charactersIgnoringModifiers: "ignored")
            XCTAssertEqual(event.command, .key(key, modifiers: ["cmd", "shift", "alt", "ctrl"]))
        }
    }

    func testSpecialKeyCodeTakesPrecedenceOverPasteCharacters() {
        let event = ControlKeyboardEvent(
            keyCode: 0x24, modifierFlags: [.command], characters: "v", charactersIgnoringModifiers: "v")
        XCTAssertEqual(event.command, .key("enter", modifiers: ["cmd"]))
    }

    func testCommandPasteUsesNativeCommandWithoutAdditionalModifiers() {
        for characters in ["v", "V"] {
            let event = ControlKeyboardEvent(
                keyCode: 0x09, modifierFlags: [.command, .shift, .option, .control],
                characters: characters, charactersIgnoringModifiers: characters)
            XCTAssertTrue(event.isPasteShortcut)
            XCTAssertEqual(event.command, .key("v", modifiers: ["cmd"]))
        }
    }

    func testShiftOnlyTypesRenderedCharactersWithoutForwardingShift() {
        let event = ControlKeyboardEvent(
            keyCode: 0x00, modifierFlags: [.shift], characters: "A", charactersIgnoringModifiers: "a")
        XCTAssertEqual(event.command, .text("A", modifiers: []))
    }

    func testShortcutUsesUnmodifiedCharactersAndStableModifierOrder() {
        let event = ControlKeyboardEvent(
            keyCode: 0x00, modifierFlags: [.control, .option, .shift, .command],
            characters: "Å", charactersIgnoringModifiers: "a")
        XCTAssertEqual(event.command, .text("a", modifiers: ["cmd", "shift", "alt", "ctrl"]))
    }

    func testOptionAndControlAlsoSelectShortcutCharacterPayload() {
        let event = ControlKeyboardEvent(
            keyCode: 0x00, modifierFlags: [.option, .control],
            characters: "å", charactersIgnoringModifiers: "a")
        XCTAssertEqual(event.command, .text("a", modifiers: ["alt", "ctrl"]))
    }

    func testEmptyOrMissingSelectedCharacterPayloadProducesNoCommand() {
        XCTAssertNil(ControlKeyboardEvent(keyCode: 0x00).command)
        XCTAssertNil(ControlKeyboardEvent(keyCode: 0x00, characters: "").command)
        XCTAssertNil(
            ControlKeyboardEvent(
                keyCode: 0x00, modifierFlags: [.command], characters: "a"
            ).command)
        XCTAssertNil(ControlKeyboardEvent(keyCode: 0x00, charactersIgnoringModifiers: "a").command)
    }

    func testPasteDetectionRequiresCommandAndLetterV() {
        let plain = ControlKeyboardEvent(keyCode: 0x09, characters: "v", charactersIgnoringModifiers: "v")
        XCTAssertFalse(plain.isPasteShortcut)
        XCTAssertEqual(plain.command, .text("v", modifiers: []))
        XCTAssertFalse(
            ControlKeyboardEvent(
                keyCode: 0x08, modifierFlags: [.command], charactersIgnoringModifiers: "c"
            ).isPasteShortcut)
    }
}

final class ControlMousePositionTests: XCTestCase {
    func testPhonePixelTargetSurvivesAspectFitScalingAndVerticalFlip() throws {
        let layout = try XCTUnwrap(
            ControlImageLayout(
                screenSize: CGSize(width: 750, height: 1334),
                bounds: CGRect(x: 0, y: 0, width: 500, height: 800)))

        // Select phone pixel (500, 500) in the displayed 750×1334 image.
        let scale = 800.0 / 1334.0
        let displayed = CGPoint(
            x: layout.imageRect.minX + 500 * scale,
            y: layout.imageRect.maxY - 500 * scale)
        let target = try XCTUnwrap(layout.normalizedPoint(displayed))

        XCTAssertEqual(target.x * 750, 500, accuracy: 0.000_001)
        XCTAssertEqual(target.y * 1334, 500, accuracy: 0.000_001)
    }

    func testPortraitSideBarsAreExcludedAndDragClampsToPhoneEdges() throws {
        let layout = try XCTUnwrap(
            ControlImageLayout(
                screenSize: CGSize(width: 200, height: 400),
                bounds: CGRect(x: 0, y: 0, width: 400, height: 400)))

        XCTAssertEqual(layout.imageRect, CGRect(x: 100, y: 0, width: 200, height: 400))
        XCTAssertNil(layout.normalizedPoint(CGPoint(x: 50, y: 200)))
        XCTAssertNil(layout.normalizedPoint(CGPoint(x: 350, y: 200)))
        XCTAssertEqual(layout.normalizedPoint(CGPoint(x: 100, y: 400)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(layout.normalizedPoint(CGPoint(x: 300, y: 0)), CGPoint(x: 1, y: 1))
        XCTAssertEqual(layout.normalizedPoint(CGPoint(x: -50, y: 500), clamp: true), CGPoint(x: 0, y: 0))
        XCTAssertEqual(layout.normalizedPoint(CGPoint(x: 500, y: -50), clamp: true), CGPoint(x: 1, y: 1))
    }

    func testLandscapeTopAndBottomBarsRespectViewBoundsOrigin() throws {
        let layout = try XCTUnwrap(
            ControlImageLayout(
                screenSize: CGSize(width: 400, height: 200),
                bounds: CGRect(x: 20, y: 30, width: 400, height: 400)))

        XCTAssertEqual(layout.imageRect, CGRect(x: 20, y: 130, width: 400, height: 200))
        XCTAssertNil(layout.normalizedPoint(CGPoint(x: 220, y: 100)))
        XCTAssertNil(layout.normalizedPoint(CGPoint(x: 220, y: 350)))
        XCTAssertEqual(layout.normalizedPoint(CGPoint(x: 120, y: 280)), CGPoint(x: 0.25, y: 0.25))
    }

    func testResizeReprojectsStationaryMouseUsingNewImageRectangle() throws {
        let screen = CGSize(width: 200, height: 400)
        let original = try XCTUnwrap(
            ControlImageLayout(
                screenSize: screen, bounds: CGRect(x: 0, y: 0, width: 400, height: 400)))
        let resized = try XCTUnwrap(
            ControlImageLayout(
                screenSize: screen, bounds: CGRect(x: 0, y: 0, width: 400, height: 800)))
        let mouse = CGPoint(x: 200, y: 200)
        var position = ControlMousePosition()
        position.update(try XCTUnwrap(original.normalizedPoint(mouse)))
        XCTAssertEqual(position.takePosition(), CGPoint(x: 0.5, y: 0.5))

        position.reset()
        position.update(try XCTUnwrap(resized.normalizedPoint(mouse)))

        XCTAssertEqual(position.takePosition(), CGPoint(x: 0.5, y: 0.75))
    }

    func testStationaryMouseDoesNotReassertWindowPositionAfterAnAPITap() {
        let mouse = CGPoint(x: 0.3, y: 0.4)
        var position = ControlMousePosition()
        position.update(mouse)
        XCTAssertEqual(position.takePosition(), mouse)

        // An API tap can now move the phone elsewhere. Without Mac movement,
        // subsequent timer samples must produce no window input at all.
        for _ in 0..<60 {
            position.update(mouse)
            XCTAssertNil(position.takePosition())
        }

        let moved = CGPoint(x: 0.31, y: 0.4)
        position.update(moved)
        XCTAssertEqual(position.takePosition(), moved)
    }

    func testEventAndPollingKeepTheLatestPositionIncludingTheFinalEvent() {
        var position = ControlMousePosition()
        position.update(CGPoint(x: 0.1, y: 0.2))
        position.update(CGPoint(x: 0.3, y: 0.4))
        let final = CGPoint(x: 0.5, y: 0.6)
        position.update(final)
        position.update(final)

        XCTAssertEqual(position.takePosition(), final)
        XCTAssertNil(position.takePosition())
    }

    func testClickSupersedesPendingHoverAndReleaseDoesNotTriggerAnotherMove() {
        var position = ControlMousePosition()
        position.update(CGPoint(x: 0.1, y: 0.2))
        let click = CGPoint(x: 0.6, y: 0.7)
        position.markSubmitted(click)
        position.update(click)
        XCTAssertNil(position.takePosition())

        position.update(CGPoint(x: 0.7, y: 0.8))
        let release = CGPoint(x: 0.8, y: 0.9)
        position.markSubmitted(release)
        position.update(release)
        XCTAssertNil(position.takePosition())
    }

    func testReentryOrReadinessResetSubmitsEvenTheSameWindowPosition() {
        let mouse = CGPoint(x: 0.3, y: 0.4)
        var position = ControlMousePosition()
        position.update(mouse)
        _ = position.takePosition()
        position.update(CGPoint(x: 0.6, y: 0.7))

        position.reset()
        XCTAssertNil(position.takePosition())
        position.update(mouse)

        XCTAssertEqual(position.takePosition(), mouse)
    }

    func testInvalidImageGeometryAndNonfiniteEventsProduceNoCoordinates() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        XCTAssertNil(ControlImageLayout(screenSize: .zero, bounds: bounds))
        XCTAssertNil(ControlImageLayout(screenSize: CGSize(width: 200, height: 400), bounds: .zero))
        let layout = try XCTUnwrap(
            ControlImageLayout(
                screenSize: CGSize(width: 200, height: 400), bounds: bounds))
        XCTAssertNil(layout.normalizedPoint(CGPoint(x: CGFloat.nan, y: 100), clamp: true))
    }
}
