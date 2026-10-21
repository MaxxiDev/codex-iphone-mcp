import AppKit
import CoreImage

enum ClipboardQRCodeError: Error, CustomStringConvertible {
    case textTooLong
    case generationFailed

    var description: String {
        switch self {
        case .textTooLong: "文字超过单个二维码容量（约 2.8 KB），请分段发送"
        case .generationFailed: "无法生成文字二维码，请重试"
        }
    }
}

enum ClipboardQRCode {
    // QR byte mode supports at most 2,953 bytes at error-correction level L.
    // Leave headroom for Core Image's encoding choices and keep one scan reliable.
    static let maxUTF8Bytes = 2_800

    static func payload(for text: String) throws -> Data {
        let data = Data(text.utf8)
        guard data.count <= maxUTF8Bytes else { throw ClipboardQRCodeError.textTooLong }
        return data
    }

    static func image(for text: String) throws -> NSImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw ClipboardQRCodeError.generationFailed
        }
        filter.setValue(try payload(for: text), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw ClipboardQRCodeError.generationFailed }

        let quietZone = output.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: .white).cropped(to: quietZone)
        let padded = output.composited(over: background)
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 5, y: 5))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            throw ClipboardQRCodeError.generationFailed
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
