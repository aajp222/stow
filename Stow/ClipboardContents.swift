import AppKit

/// What "Add Clipboard Contents to Stow" found on the clipboard, in order of
/// preference: files first, then an image, a link, and finally plain text.
enum ClipboardContents {
    case files([URL])
    /// PNG data.
    case image(Data)
    case link(URL)
    case text(String)

    static func read(from pasteboard: NSPasteboard = .general) -> ClipboardContents? {
        // Files copied in Finder (⌘C) arrive as file URLs.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        if let png = pasteboard.data(forType: .png) {
            return .image(png)
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return .image(png)
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, !url.isFileURL {
            return .link(url)
        }
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        return nil
    }

    /// A quick check for the menu, without reading or converting any data.
    static func isAvailable(on pasteboard: NSPasteboard = .general) -> Bool {
        guard let types = pasteboard.types else { return false }
        return !Set(types).isDisjoint(with: [.fileURL, .png, .tiff, .URL, .string])
    }

    /// A safe file name (without extension) from the start of some text: its first
    /// line, at most 40 characters, with the characters macOS doesn't allow in names
    /// replaced.
    static func fileName(for text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let safe = firstLine
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let short = String(safe.prefix(40)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty || short.hasPrefix(".") ? "Clipboard Text" : short
    }
}
