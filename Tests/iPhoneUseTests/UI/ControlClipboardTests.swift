import XCTest
import Vision

@testable import iPhoneUse

final class ControlClipboardTests: XCTestCase {
    func testClipboardTextIsTypedWithoutSendingNativePaste() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = makeInput { reports.append(($0, $1)) }

        try ControlShortcut.sendClipboard.perform(on: input, clipboardText: "aA!")

        XCTAssertTrue(reports.allSatisfy { $0.0 == .keyboard })
        let presses = reports.map { $0.1 }.filter { $0[2] != 0 }
        XCTAssertEqual(presses.map { $0[2] }, [0x04, 0x04, 0x1E])
        XCTAssertEqual(presses.map { $0[0] }, [0, KeyboardMap.shift, KeyboardMap.shift])
        XCTAssertTrue(reports.allSatisfy { $0.1[0] & 0x08 == 0 })
        XCTAssertEqual(reports.last?.1, Array(repeating: 0, count: 8))
    }

    func testUnsupportedCharactersRejectBeforeAnyPartialHIDInput() {
        var reports: [(ReportID, [UInt8])] = []
        let input = makeInput { reports.append(($0, $1)) }

        for text in ["prefix中文", "prefix🙂", "prefixé", "prefix\u{0000}"] {
            XCTAssertThrowsError(try ControlShortcut.sendClipboard.perform(on: input, clipboardText: text)) { error in
                guard case ClipboardInputError.unsupportedText = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }

        XCTAssertTrue(reports.isEmpty)
    }

    func testQRCodePreservesUnicodeAsUTF8AndRejectsOversizedText() throws {
        let text = "中文、emoji 🙂、accent é、line\nbreak"
        XCTAssertEqual(try ClipboardQRCode.payload(for: text), Data(text.utf8))

        XCTAssertNoThrow(try ClipboardQRCode.payload(for: String(repeating: "界", count: 900)))
        XCTAssertThrowsError(
            try ClipboardQRCode.payload(for: String(repeating: "界", count: 1_000))) { error in
                guard case ClipboardQRCodeError.textTooLong = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
    }

    func testGeneratedQRCodeDecodesToTheOriginalUnicodeText() throws {
        let text = "中文 🙂 café\n第二行"
        XCTAssertEqual(try decodeQRCode(ClipboardQRCode.image(for: text)), text)
    }

    func testLargestAllowedQRCodePayloadDecodesWithoutTruncation() throws {
        let text = String(repeating: "界", count: 933) + "x"
        XCTAssertEqual(text.utf8.count, ClipboardQRCode.maxUTF8Bytes)
        XCTAssertEqual(try decodeQRCode(ClipboardQRCode.image(for: text)), text)
    }

    private func decodeQRCode(_ image: NSImage) throws -> String? {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return request.results?.first?.payloadStringValue
    }

    func testEmptyAndMissingClipboardTextSendNoKeys() {
        var reports: [(ReportID, [UInt8])] = []
        let input = makeInput { reports.append(($0, $1)) }

        for text in [nil, ""] as [String?] {
            XCTAssertThrowsError(try ControlShortcut.sendClipboard.perform(on: input, clipboardText: text)) { error in
                guard case ClipboardInputError.noText = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }

        XCTAssertTrue(reports.isEmpty)
    }

    func testClipboardLineEndingsAreTypedAsSingleReturns() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = makeInput { reports.append(($0, $1)) }

        try ControlShortcut.sendClipboard.perform(on: input, clipboardText: "a\r\nb\rc\n\t")

        let presses = reports.map { $0.1 }.filter { $0[2] != 0 }
        XCTAssertEqual(presses.map { $0[2] }, [0x04, 0x28, 0x05, 0x28, 0x06, 0x28, 0x2B])
    }

    func testNativePasteStillSendsOnlyCommandV() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = makeInput { reports.append(($0, $1)) }

        try ControlShortcut.paste.perform(on: input, clipboardText: "clipboard must not be typed")

        XCTAssertEqual(reports.map { $0.0 }, [.keyboard, .keyboard, .keyboard, .keyboard])
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [8, 0, 0, 0, 0, 0, 0, 0], [8, 0, 0x19, 0, 0, 0, 0, 0],
                [8, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
            ])
    }

    private func makeInput(sender: @escaping (ReportID, [UInt8]) -> Void) -> DeviceInput {
        DeviceInput(host: UUID(), session: UUID(), sleep: { _ in }, reportSender: sender)
    }
}
