import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Image work that needs Vision or Core Image. Results go into the caller's folder
/// so they can be managed like the other Quick Actions, without changing originals.
enum ImageActions {
    /// Keep all the foreground subjects and the full canvas. Vision makes a soft,
    /// source-resolution cutout, rather than enlarging its low-resolution label mask.
    @concurrent
    nonisolated static func removeBackground(_ url: URL, into folder: URL) async throws -> URL {
        try Task.checkCancellation()
        let (image, orientation) = try readImage(url)
        // Bake rotation in before Vision runs: the mask and the saved PNG then have
        // the same upright pixels, even when a viewer ignores EXIF metadata.
        let upright = CIImage(cgImage: image).oriented(orientation)
        let context = CIContext()
        guard let source = context.createCGImage(upright, from: upright.extent) else {
            throw ImageActionError.unreadableImage(url.lastPathComponent)
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ImageActionError.noSubject
        }
        let buffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false
        )
        let cutout = CIImage(cvPixelBuffer: buffer)
        guard let result = context.createCGImage(cutout, from: cutout.extent) else {
            throw ImageActionError.cantMakeImage
        }
        try Task.checkCancellation()
        return try savePNG(result, into: folder, named: url.deletingPathExtension().lastPathComponent + " (no background)")
    }

    /// OCR runs locally, including PDFs whose pages are only scans. Render one page
    /// at a time at 216 dpi, capped for unusually large paper to avoid huge bitmaps.
    @concurrent
    nonisolated static func recognizeText(in url: URL) async throws -> String {
        try Task.checkCancellation()
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        var pages: [String] = []
        if QuickActions.isPDF(url) {
            guard let document = CGPDFDocument(url as CFURL), document.isUnlocked else {
                throw ImageActionError.unreadablePDF(url.lastPathComponent)
            }
            for index in 0..<document.numberOfPages {
                try Task.checkCancellation()
                let image = try autoreleasepool {
                    guard let page = document.page(at: index + 1) else {
                        throw ImageActionError.unreadablePDF(url.lastPathComponent)
                    }
                    return try render(page, named: url.lastPathComponent)
                }
                pages.append(textInReadingOrder(try await request.perform(on: image, orientation: .up)))
            }
        } else {
            let (image, orientation) = try readImage(url)
            pages.append(textInReadingOrder(try await request.perform(on: image, orientation: orientation)))
        }
        try Task.checkCancellation()
        let text = pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { throw ImageActionError.noText }
        return text
    }

    /// Use whole pixels per QR module and four white modules on every side. A
    /// fractional scale or interpolation blurs the squares and makes scanning harder.
    nonisolated static func qrCode(for string: String, into folder: URL, named name: String) throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw ImageActionError.invalidName
        }
        guard !string.isEmpty else { throw ImageActionError.emptyQRCode }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        // A QR image is tiny before scaling; rendering it on the CPU also works
        // when a background process has no Metal device available.
        guard let code = filter.outputImage,
              let small = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(code, from: code.extent) else {
            throw ImageActionError.cantMakeQRCode
        }
        let scale = max(1, Int((1024.0 / Double(small.width + 8)).rounded()))
        let size = (small.width + 8) * scale
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ImageActionError.cantMakeQRCode }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(small, in: CGRect(x: 4 * scale, y: 4 * scale, width: small.width * scale, height: small.height * scale))
        guard let result = context.makeImage() else { throw ImageActionError.cantMakeQRCode }
        return try savePNG(result, into: folder, named: name + " QR")
    }

    nonisolated private static func readImage(_ url: URL) throws -> (CGImage, CGImagePropertyOrientation) {
        guard QuickActions.isImage(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageActionError.unreadableImage(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let value = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (image, CGImagePropertyOrientation(rawValue: value) ?? .up)
    }

    nonisolated private static func render(_ page: CGPDFPage, named name: String) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            throw ImageActionError.unreadablePDF(name)
        }
        let rotated = abs(page.rotationAngle % 180) == 90
        let scale = min(3, 6000 / max(box.width, box.height))
        let width = max(1, Int(ceil((rotated ? box.height : box.width) * scale)))
        let height = max(1, Int(ceil((rotated ? box.width : box.height) * scale)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ImageActionError.unreadablePDF(name) }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ImageActionError.unreadablePDF(name) }
        return image
    }

    /// Split at whitespace between paragraphs or columns before ordering lines.
    /// Sorting just by height would interleave the left and right columns of a page.
    nonisolated private static func textInReadingOrder(_ observations: [RecognizedTextObservation]) -> String {
        let lines = observations.compactMap { observation -> TextLine? in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, observation.boundingBox.width > 0, observation.boundingBox.height > 0 else { return nil }
            return TextLine(text: text, box: observation.boundingBox.cgRect, rightToLeft: observation.textDirection == .rightToLeft)
        }
        return orderedText(lines)
    }

    private struct TextLine: Sendable {
        let text: String
        let box: CGRect
        let rightToLeft: Bool
    }

    nonisolated private static func orderedText(_ lines: [TextLine]) -> String {
        guard lines.count > 1 else { return lines.first?.text ?? "" }
        let heights = lines.map(\.box.height).sorted()
        let typicalHeight = heights[heights.count / 2]
        // Read a whole column before the next, even when both columns happen to
        // have paragraph breaks at the same height. A spanning heading blocks this
        // cut and is separated horizontally before we look for columns again.
        let leftRight = lines.sorted { $0.box.minX < $1.box.minX }
        var right = leftRight[0].box.maxX
        for index in 1..<leftRight.count {
            if leftRight[index].box.minX - right > typicalHeight {
                let left = Array(leftRight[..<index])
                let other = Array(leftRight[index...])
                let blocks = lines.filter(\.rightToLeft).count > lines.count / 2 ? [other, left] : [left, other]
                return blocks.map { orderedText($0) }.joined(separator: "\n\n")
            }
            right = max(right, leftRight[index].box.maxX)
        }
        let topDown = lines.sorted { $0.box.maxY > $1.box.maxY }
        var bottom = topDown[0].box.minY
        for index in 1..<topDown.count {
            if bottom - topDown[index].box.maxY > typicalHeight * 0.9 {
                return orderedText(Array(topDown[..<index])) + "\n\n" + orderedText(Array(topDown[index...]))
            }
            bottom = min(bottom, topDown[index].box.minY)
        }
        // Group observations on the same baseline without a non-transitive sort
        // comparator, which can otherwise scramble slightly slanted lines.
        var remaining = topDown
        var rows: [String] = []
        while let first = remaining.first {
            let row = remaining.filter { abs($0.box.midY - first.box.midY) < min($0.box.height, first.box.height) * 0.5 }
            remaining.removeAll { abs($0.box.midY - first.box.midY) < min($0.box.height, first.box.height) * 0.5 }
            let rtl = row.filter(\.rightToLeft).count > row.count / 2
            rows.append(row.sorted { rtl ? $0.box.minX > $1.box.minX : $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " "))
        }
        return rows.joined(separator: "\n")
    }

    /// Encode before creating the result. A failed encoder leaves no partial PNG,
    /// and an exclusive write won't replace a file another action just created.
    nonisolated private static func savePNG(_ image: CGImage, into folder: URL, named name: String) throws -> URL {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageActionError.cantWrite(name + ".png")
        }
        CGImageDestinationAddImage(encoder, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw ImageActionError.cantWrite(name + ".png") }
        var number = 1
        while true {
            let stem = number == 1 ? name : "\(name) \(number)"
            let url = folder.appending(path: stem + ".png")
            do {
                try (data as Data).write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                number += 1
            } catch {
                throw ImageActionError.cantWrite(url.lastPathComponent)
            }
        }
    }
}

enum ImageActionError: LocalizedError {
    case unreadableImage(String)
    case unreadablePDF(String)
    case noSubject
    case noText
    case cantMakeImage
    case emptyQRCode
    case cantMakeQRCode
    case invalidName
    case cantWrite(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let name): "“\(name)” couldn't be read as an image."
        case .unreadablePDF(let name): "“\(name)” couldn't be read as a PDF. If it's password-protected, unlock it first."
        case .noSubject: "No foreground subject was found. Try a photo with a clearer subject."
        case .noText: "No text was found in this file."
        case .cantMakeImage: "The foreground image couldn't be created. Try another photo."
        case .emptyQRCode: "Enter some text or a link for the QR code."
        case .cantMakeQRCode: "A QR code couldn't be created. Try using less text."
        case .invalidName: "Enter a file name without /, : or a null character."
        case .cantWrite(let name): "“\(name)” couldn't be saved. Check that the destination folder is available and writable."
        }
    }
}
