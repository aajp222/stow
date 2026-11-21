import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Stow

/// Draws its own inputs, so image tests don't depend on downloaded photos or fonts.
struct ImageActionsTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "StowImageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func context(width: Int = 1200, height: Int = 1000) throws -> CGContext {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private func draw(_ text: String, at point: CGPoint, in context: CGContext, size: CGFloat = 56) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }

    private func save(_ image: CGImage, named name: String = "Image.png", orientation: Int = 1) throws -> URL {
        let url = folder.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func image(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let bitmap = try context(width: image.width, height: image.height)
        bitmap.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    @Test(arguments: ["https://example.com/stow?hello=world", "Hello Stow!", "日本語と絵文字 🦀"])
    func qrCodeRoundTrips(_ message: String) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try ImageActions.qrCode(for: message, into: folder, named: "Link")
        #expect(url.lastPathComponent == "Link QR.png")
        let generated = try image(at: url)
        #expect(generated.width == generated.height)
        #expect(abs(generated.width - 1024) < 100)
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: CIImage(cgImage: generated)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(codes == [message])
        let bytes = try pixels(generated)
        // Every pixel is black or white, and the entire border is quiet white.
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let value = bytes[offset]
            if value != 0 && value != 255 {
                Issue.record("QR modules must have sharp, uninterpolated edges.")
                break
            }
            if bytes[offset + 1] != value || bytes[offset + 2] != value || bytes[offset + 3] != 255 {
                Issue.record("QR pixels must be opaque black or white.")
                break
            }
        }
        for index in 0..<generated.width {
            #expect(bytes[index * 4] == 255)
            #expect(bytes[(generated.width * (generated.height - 1) + index) * 4] == 255)
            #expect(bytes[(index * generated.width) * 4] == 255)
            #expect(bytes[(index * generated.width + generated.width - 1) * 4] == 255)
        }
    }

    @Test func outputNamesAreUniqueAndKeepDotsInTheStem() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputs = try (1...3).map { _ in try ImageActions.qrCode(for: "Stow", into: folder, named: "Version 1.2") }
        #expect(outputs.map(\.lastPathComponent) == ["Version 1.2 QR.png", "Version 1.2 QR 2.png", "Version 1.2 QR 3.png"])
        let first = try Data(contentsOf: outputs[0])
        #expect(try outputs.allSatisfy { try Data(contentsOf: $0) == first })
    }

    @Test func qrCodeRejectsEmptyTextInvalidNamesAndMissingFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["", " ", "a/b", "a:b", "a\0b"] {
            #expect(throws: ImageActionError.self) {
                try ImageActions.qrCode(for: "Stow", into: folder, named: name)
            }
        }
        #expect(throws: ImageActionError.self) { try ImageActions.qrCode(for: "", into: folder, named: "Empty") }
        #expect(throws: ImageActionError.self) {
            try ImageActions.qrCode(for: "Stow", into: folder.appending(path: "missing"), named: "Link")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func ocrReadsDrawnWordsAndPreservesParagraphs() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try context()
        draw("Hello Stow", at: CGPoint(x: 80, y: 820), in: bitmap)
        draw("Keep these words", at: CGPoint(x: 80, y: 745), in: bitmap)
        draw("Another paragraph", at: CGPoint(x: 80, y: 440), in: bitmap)
        let source = try save(try #require(bitmap.makeImage()))
        let text = try await ImageActions.recognizeText(in: source)
        #expect(text.localizedCaseInsensitiveContains("Hello Stow\nKeep these words"))
        #expect(text.localizedCaseInsensitiveContains("\n\nAnother paragraph"))
    }

    @Test func ocrReadsColumnsBeforeMovingToTheNextColumn() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try context(width: 2200, height: 1100)
        draw("First column", at: CGPoint(x: 100, y: 850), in: bitmap)
        draw("Apple orchard", at: CGPoint(x: 100, y: 775), in: bitmap)
        draw("Left paragraph", at: CGPoint(x: 100, y: 400), in: bitmap)
        draw("Second column", at: CGPoint(x: 1200, y: 850), in: bitmap)
        draw("Orange garden", at: CGPoint(x: 1200, y: 775), in: bitmap)
        draw("Right paragraph", at: CGPoint(x: 1200, y: 400), in: bitmap)
        let source = try save(try #require(bitmap.makeImage()))
        let text = try await ImageActions.recognizeText(in: source).lowercased()
        #expect(text.contains("first column\napple orchard\n\nleft paragraph\n\nsecond column\norange garden\n\nright paragraph"))
    }

    @Test func ocrHonoursEXIFOrientation() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try context()
        draw("Orientation matters", at: CGPoint(x: 80, y: 700), in: bitmap)
        let upright = CIImage(cgImage: try #require(bitmap.makeImage()))
        let sideways = upright.oriented(.left)
        let stored = try #require(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(sideways, from: sideways.extent))
        let source = try save(stored, orientation: 6)
        let text = try await ImageActions.recognizeText(in: source)
        #expect(text.localizedCaseInsensitiveContains("Orientation matters"))
    }

    @Test func ocrReadsEveryPDFPageIncludingScannedPages() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Pages.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 500)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        pdf.beginPDFPage(nil)
        draw("First page", at: CGPoint(x: 50, y: 350), in: pdf, size: 30)
        pdf.endPDFPage()
        pdf.beginPDFPage(nil)
        pdf.endPDFPage()
        let scan = try context()
        draw("Scanned final page", at: CGPoint(x: 70, y: 700), in: scan)
        pdf.beginPDFPage(nil)
        pdf.draw(try #require(scan.makeImage()), in: bounds)
        pdf.endPDFPage()
        pdf.closePDF()
        let text = try await ImageActions.recognizeText(in: url)
        #expect(text.localizedCaseInsensitiveContains("First page\n\nScanned final page"))
    }

    @Test func blankImagesAndPDFsHaveFriendlyNoTextErrors() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try save(try #require(try context().makeImage()))
        do {
            _ = try await ImageActions.recognizeText(in: source)
            Issue.record("A blank image should have no text.")
        } catch ImageActionError.noText { }
        let url = folder.appending(path: "Blank.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        pdf.beginPDFPage(nil)
        pdf.endPDFPage()
        pdf.closePDF()
        do {
            _ = try await ImageActions.recognizeText(in: url)
            Issue.record("A blank PDF should have no text.")
        } catch ImageActionError.noText { }
    }

    @Test func unreadableInputsAreRefused() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Broken.png", "Broken.pdf", "Notes.txt"] {
            let url = folder.appending(path: name)
            try Data("not an image or a PDF".utf8).write(to: url)
            await #expect(throws: ImageActionError.self) { try await ImageActions.recognizeText(in: url) }
            await #expect(throws: ImageActionError.self) { try await ImageActions.removeBackground(url, into: folder) }
        }
    }

    @Test(arguments: [1, 6])
    func foregroundCutoutKeepsResolutionAndTransparency(_ orientation: Int) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try context(width: 900, height: 600)
        bitmap.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1))
        bitmap.fillEllipse(in: CGRect(x: 270, y: 120, width: 360, height: 360))
        let source = try save(try #require(bitmap.makeImage()), named: "Disc.png", orientation: orientation)
        let original = try Data(contentsOf: source)
        let output: URL
        do {
            output = try await ImageActions.removeBackground(source, into: folder)
        } catch ImageActionError.noSubject {
            // Vision is trained on photographs and may find no subject in a drawn
            // disc. In that case there is no cutout whose pixels we can assert on.
            #expect(try Data(contentsOf: source) == original)
            return
        }
        #expect(output.lastPathComponent == "Disc (no background).png")
        let cutout = try image(at: output)
        #expect(cutout.width == (orientation == 6 ? 600 : 900))
        #expect(cutout.height == (orientation == 6 ? 900 : 600))
        let data = try pixels(cutout)
        let corners = [0, cutout.width - 1, (cutout.height - 1) * cutout.width, cutout.height * cutout.width - 1]
        for corner in corners { #expect(data[corner * 4 + 3] < 10) }
        let centre = (cutout.height / 2 * cutout.width + cutout.width / 2) * 4
        #expect(data[centre + 3] > 245)
        #expect(data[centre] > data[centre + 1])
        #expect(try Data(contentsOf: source) == original)
        let second = try await ImageActions.removeBackground(source, into: folder)
        #expect(second.lastPathComponent == "Disc (no background) 2.png")
    }
}
