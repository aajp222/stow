import Foundation

/// One thing sitting on the shelf.
///
/// What the item *is* lives in the `Content` enum, so Phase 4 can add text, links
/// and images as new cases without reshaping the model or the code that stores it.
struct ShelfItem: Identifiable, Equatable {
    enum Content: Equatable {
        /// A reference to a file or folder where it already lives on disk.
        /// Stow never copies these.
        case file(URL)
    }

    let id: UUID
    let content: Content
    /// True when the file is Stow's own copy in its Promised folder: it arrived as a
    /// file promise (a screenshot thumbnail, a Photos drag, a Mail attachment...) or
    /// was made from the clipboard. Stow is responsible for cleaning those up.
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
        switch content {
        case .file(let url): url
        }
    }

    var displayName: String {
        switch content {
        case .file(let url): url.lastPathComponent
        }
    }
}
