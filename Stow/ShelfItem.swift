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
    /// True when the file arrived as a file promise (a screenshot thumbnail, a Photos
    /// drag, a Mail attachment...). The source app wrote that file into Stow's
    /// Promised folder, so it's Stow's copy and Stow is responsible for cleaning it up.
    let isPromisedCopy: Bool

    init(content: Content, isPromisedCopy: Bool = false) {
        self.id = UUID()
        self.content = content
        self.isPromisedCopy = isPromisedCopy
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
