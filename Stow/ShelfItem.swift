import AppKit

/// One thing sitting on the shelf.
///
/// What the item *is* lives in the `Content` enum: a file, a bit of text, or a web
/// link. Images arrive as files: a dragged or pasted picture is saved as a PNG in
/// Stow's folder, so it drags out anywhere a file can go.
struct ShelfItem: Identifiable, Equatable {
    enum Content: Equatable {
        /// A reference to a file or folder where it already lives on disk.
        /// Stow never copies these.
        case file(URL)
        /// Plain text, such as a paragraph dragged out of a web page.
        case text(String)
        /// A web link. `title` is the page title when the source app provided one.
        case link(URL, title: String?)
    }

    let id: UUID
    let content: Content
    /// True when the file is Stow's own copy in its Promised folder: it arrived as a
    /// file promise (a screenshot thumbnail, a Photos drag, a Mail attachment...) or
    /// was made from an image. Stow is responsible for cleaning those up.
    let isStowCopy: Bool

    init(id: UUID = UUID(), content: Content, isStowCopy: Bool = false) {
        self.id = id
        self.content = content
        self.isStowCopy = isStowCopy
    }

    /// The same item (same id, so it keeps its place and selection) pointing at the
    /// file's new location after a rename or move.
    func relocated(to url: URL, isStowCopy: Bool) -> ShelfItem {
        ShelfItem(id: id, content: .file(url), isStowCopy: isStowCopy)
    }

    var fileURL: URL? {
        if case .file(let url) = content { url } else { nil }
    }

    var displayName: String {
        switch content {
        case .file(let url):
            url.lastPathComponent
        case .text(let text):
            text.split(whereSeparator: \.isNewline).first
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(60)) } ?? "Text"
        case .link(let url, let title):
            title ?? url.host() ?? url.absoluteString
        }
    }

    /// What goes on a pasteboard when the item is dragged out or copied. Each kind
    /// writes the form other apps expect: Finder turns a file URL into a copy of the
    /// file, a web URL into a .webloc, and text into a text clipping.
    var pasteboardWriter: NSPasteboardWriting {
        switch content {
        case .file(let url): url as NSURL
        case .text(let text): text as NSString
        case .link(let url, _): url as NSURL
        }
    }

    /// The same content as a plain value, for the Share menu.
    var shareableValue: Any {
        switch content {
        case .file(let url): url
        case .text(let text): text
        case .link(let url, _): url
        }
    }
}
