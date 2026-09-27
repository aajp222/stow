import AppKit
import QuickLookThumbnailing

/// Makes the pictures shown for shelf items: the Finder icon straight away, then a
/// real Quick Look thumbnail (a preview of the image, PDF page, video frame...) once
/// QuickLookThumbnailing has rendered one.
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSURL, NSImage>()

    /// The item's Finder icon. Cheap and synchronous, so it's used as the placeholder.
    func icon(for item: ShelfItem) -> NSImage {
        switch item.content {
        case .file(let url):
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    /// A Quick Look thumbnail, or nil if the file can't be previewed.
    func thumbnail(for item: ShelfItem, size: CGSize, scale: CGFloat) async -> NSImage? {
        switch item.content {
        case .file(let url):
            return await thumbnail(forFileAt: url, size: size, scale: scale)
        }
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
