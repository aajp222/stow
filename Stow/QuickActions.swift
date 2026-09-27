import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The work behind the right-click menu's Quick Actions: making new files from shelf
/// items. Each one writes its result into `folder` (a fresh folder in Stow's own
/// storage) and returns it; ShelfContextMenu then puts it on the shelf next to the
/// original.
///
/// These run off the main thread, since zipping or converting big files takes a
/// moment, so they're `nonisolated` (the project makes everything main-actor by
/// default) and only touch the files they're given.
enum QuickActions {
    /// Image formats Stow can convert to. HEIC depends on the Mac's encoders, so it's
    /// only offered when ImageIO can write it.
    static var conversionTypes: [UTType] {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return [UTType.jpeg, .png, .heic].filter { writable.contains($0.identifier) }
    }

    nonisolated static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    nonisolated static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
    }

    // MARK: - Compress

    /// Zips the files, like Finder's Compress: one folder becomes "<folder>.zip",
    /// anything else is gathered into a folder first ("<file>.zip" for one file,
    /// "Archive.zip" for several).
    ///
    /// There's no zip API as such. Asking NSFileCoordinator to read a *folder* "for
    /// uploading" makes the system zip it into a temporary file, which works inside
    /// the sandbox without running any other program.
    nonisolated static func compress(_ urls: [URL], into folder: URL) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let source: URL
        var scratch: URL?
        if urls.count == 1, fileManager.fileExists(atPath: urls[0].path, isDirectory: &isDirectory), isDirectory.boolValue {
            source = urls[0]
        } else {
            let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
            let temporary = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            scratch = temporary
            source = temporary.appending(path: name, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
            for url in urls {
                // copyItem clones on APFS, so this is quick even for big files.
                try fileManager.copyItem(at: url, to: uniqueURL(in: source, named: url.lastPathComponent))
            }
        }
        defer {
            if let scratch {
                try? fileManager.removeItem(at: scratch)
            }
        }

        let destination = uniqueURL(in: folder, named: source.lastPathComponent + ".zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordinatorError) { zipURL in
            // The zip is deleted when this block returns, so copy it out now.
            do {
                try fileManager.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError {
            throw error
        }
        return destination
    }

    // MARK: - Images

    /// Saves the image in another format, keeping its size and metadata.
    nonisolated static func convert(_ url: URL, to type: UTType, into folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw QuickActionError.unreadableImage(url.lastPathComponent)
        }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        let name = url.deletingPathExtension().lastPathComponent
        let destination = uniqueURL(in: folder, named: name, type: type)
        try write(flattenedIfNeeded(image, for: type), as: type, to: destination, properties: properties)
        return destination
    }

    /// Scales a big photo down to at most 2048 pixels on its longer side, as a JPEG
    /// (or a PNG if it has transparency), good for email and messages.
    nonisolated static func makeSmaller(_ url: URL, into folder: URL) throws -> URL {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bake in the photo's rotation, since the metadata saying so isn't copied.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw QuickActionError.unreadableImage(url.lastPathComponent)
        }
        let type: UTType = hasTransparency(image) ? .png : .jpeg
        let name = url.deletingPathExtension().lastPathComponent + " (smaller)"
        let destination = uniqueURL(in: folder, named: name, type: type)
        try write(image, as: type, to: destination, properties: [kCGImageDestinationLossyCompressionQuality: 0.8])
        return destination
    }

    nonisolated private static func write(_ image: CGImage, as type: UTType, to url: URL, properties: [CFString: Any]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw QuickActionError.cantWrite(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw QuickActionError.cantWrite(url.lastPathComponent)
        }
    }

    nonisolated private static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// JPEG has no transparency. Without this, see-through parts (the shadow around a
    /// window screenshot, say) would turn black; put them on white instead.
    nonisolated private static func flattenedIfNeeded(_ image: CGImage, for type: UTType) -> CGImage {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard type == .jpeg, hasTransparency(image),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }

    // MARK: - PDF

    /// Puts images (one per page) and the pages of PDFs into a single PDF, in order.
    nonisolated static func combineIntoPDF(_ urls: [URL], into folder: URL) throws -> URL {
        let document = PDFDocument()
        for url in urls {
            if isPDF(url), let pdf = PDFDocument(url: url) {
                for index in 0..<pdf.pageCount {
                    // Copy the page: a page belongs to one document at a time.
                    if let page = pdf.page(at: index)?.copy() as? PDFPage {
                        document.insert(page, at: document.pageCount)
                    }
                }
            } else if isImage(url), let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                document.insert(page, at: document.pageCount)
            }
        }
        guard document.pageCount > 0 else {
            throw QuickActionError.nothingToCombine
        }
        let destination = uniqueURL(in: folder, named: "Combined", type: .pdf)
        guard document.write(to: destination) else {
            throw QuickActionError.cantWrite(destination.lastPathComponent)
        }
        return destination
    }

    // MARK: - Names

    /// `folder/name` (with `type`'s extension), or "name 2", "name 3"... if taken.
    nonisolated private static func uniqueURL(in folder: URL, named name: String, type: UTType? = nil) -> URL {
        let fileManager = FileManager.default
        let base = type == nil ? (name as NSString).deletingPathExtension : name
        let pathExtension = type?.preferredFilenameExtension ?? (name as NSString).pathExtension
        func candidate(_ number: Int) -> URL {
            let stem = number == 1 ? base : "\(base) \(number)"
            return folder.appending(path: pathExtension.isEmpty ? stem : "\(stem).\(pathExtension)")
        }
        var number = 1
        while fileManager.fileExists(atPath: candidate(number).path) {
            number += 1
        }
        return candidate(number)
    }
}

enum QuickActionError: LocalizedError {
    case unreadableImage(String)
    case cantWrite(String)
    case nothingToCombine

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let name): "“\(name)” couldn't be read as an image."
        case .cantWrite(let name): "“\(name)” couldn't be saved."
        case .nothingToCombine: "None of the items are images or PDFs."
        }
    }
}
