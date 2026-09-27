import AppKit

/// One thing arriving on the shelf, from a drop or from the clipboard.
enum IncomingItem {
    case file(URL)
    case promise(NSFilePromiseReceiver)
    case link(URL, title: String?)
    case text(String)
    /// PNG data for an image that isn't a file yet.
    case image(Data)
}

/// Reads what the shelf can take from a pasteboard: the drag pasteboard for drops,
/// the general pasteboard (the clipboard) for "Add Clipboard Contents to Stow".
enum PasteboardContents {
    /// The list of file paths that older apps put on the pasteboard instead of file
    /// URLs. Some apps still do.
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    /// The page title that browsers put next to a dragged link.
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    /// The type of a .webloc file, which a browser offers to write when a link is
    /// dragged to Finder.
    private static let weblocType = "com.apple.web-internet-location"

    /// Types that mean "files": file URLs (modern and legacy), plus all the types a
    /// file promise can arrive as.
    static let fileTypes: Set<NSPasteboard.PasteboardType> = Set(
        [.fileURL, legacyFilenamesType]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    )

    /// Every type the shelf can do something with.
    static let acceptedTypes: Set<NSPasteboard.PasteboardType> = fileTypes.union([.URL, .string, .png, .tiff])

    /// Whether the pasteboard offers anything the shelf can take, judged from its
    /// list of *types* alone, without reading any data.
    ///
    /// DragMonitor uses this while another app owns the drag. Since macOS 26, reading
    /// pasteboard *data* when the user isn't pasting or dropping is blocked (or makes
    /// macOS ask "Allow Stow to paste?"). Listing the types is still allowed.
    static func offersAcceptedTypes(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return !acceptedTypes.isDisjoint(with: types)
    }

    /// Reads everything the shelf can take, in order of preference: files and file
    /// promises, then web links, then an image, then plain text. Only the first kind
    /// found is used, because apps offer the same thing several ways at once (a
    /// dragged photo in Safari comes as a file promise, its web address, and image
    /// data), and the richest form is the one to keep.
    static func read(from pasteboard: NSPasteboard) -> [IncomingItem] {
        // Promise first: when an item offers both, the URL next to a promise can point
        // at a temporary file that disappears once the drag ends.
        let objects = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self, NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        var files: [URL] = []
        var promises: [NSFilePromiseReceiver] = []
        for object in objects {
            if let promise = object as? NSFilePromiseReceiver {
                promises.append(promise)
            } else if let url = object as? URL {
                files.append(url)
            }
        }
        if files.isEmpty, promises.isEmpty,
           let paths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] {
            files = paths.map { URL(fileURLWithPath: $0) }
        }

        let links = readLinks(from: pasteboard)
        // A link dragged out of a browser also offers to write a .webloc file.
        // Keep the link itself rather than a file about the link.
        let onlyWeblocPromises = files.isEmpty && !promises.isEmpty
            && promises.allSatisfy { $0.fileTypes.allSatisfy { $0 == weblocType } }
        if !files.isEmpty || (!promises.isEmpty && !(onlyWeblocPromises && !links.isEmpty)) {
            return files.map { .file($0) } + promises.map { .promise($0) }
        }
        if !links.isEmpty {
            return links
        }
        if let png = readImage(from: pasteboard) {
            return [.image(png)]
        }
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.text(text)]
        }
        return []
    }

    private static func readLinks(from pasteboard: NSPasteboard) -> [IncomingItem] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter { !$0.isFileURL }
        // The title only makes sense for a single link.
        let title = urls.count == 1 ? pasteboard.string(forType: urlNameType) : nil
        return urls.map { .link($0, title: title) }
    }

    private static func readImage(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        return nil
    }
}
