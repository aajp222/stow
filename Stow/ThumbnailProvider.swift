import AppKit
import QuickLookThumbnailing

/// Makes the pictures shown for shelf items: the Finder icon straight away, then a
/// real Quick Look thumbnail (a preview of the image, PDF page, video frame...) once
/// QuickLookThumbnailing has rendered one.
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSURL, NSImage>()

    /// The item's Finder icon, or a symbol for text and links. Cheap and synchronous,
    /// so it's used as the placeholder and for drag images.
    func icon(for item: ShelfItem) -> NSImage {
        switch item.content {
        case .file(let url):
            return NSWorkspace.shared.icon(forFile: url.path)
        case .text:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text") ?? NSImage()
        case .link:
            return NSImage(systemSymbolName: "link", accessibilityDescription: "Link") ?? NSImage()
        }
    }

    /// The thumbnail if it has already been made, without waiting for one.
    func cachedThumbnail(for item: ShelfItem) -> NSImage? {
        guard let url = item.fileURL else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    /// A Quick Look thumbnail, or nil if there isn't one (text and links never have one).
    func thumbnail(for item: ShelfItem, size: CGSize, scale: CGFloat) async -> NSImage? {
        guard let url = item.fileURL else { return nil }
        return await thumbnail(forFileAt: url, size: size, scale: scale)
    }

    private func thumbnail(forFileAt url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        // `.all` lets Quick Look fall back from a full thumbnail to a low-quality one
        // to the file's icon; generateBestRepresentation returns the best it managed.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
