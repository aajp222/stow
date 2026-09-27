import Foundation
import Observation

/// Saves the shelf so it survives quitting and relaunching, in
/// `~/Library/Application Support/Stow/Shelf.plist`.
///
/// Files are saved as *bookmarks*, not paths. A bookmark is macOS's durable reference
/// to a file: it still finds the file after it's been renamed or moved on the same
/// disk. When Stow loads the shelf, any file that can't be found, or that has been
/// moved to the Trash, is left off.
///
/// Stow runs in the App Sandbox, so these are *security-scoped* bookmarks. A sandboxed
/// app may only open a file you gave it (by dropping it, say). A security-scoped
/// bookmark carries that permission across relaunches, but it only applies between
/// `startAccessingSecurityScopedResource()` and `stopAccessingSecurityScopedResource()`.
final class ShelfArchive {
    private struct Record: Codable {
        enum Kind: String, Codable {
            case file, text, link
        }

        var id: UUID
        var kind: Kind
        var bookmark: Data? = nil
        var text: String? = nil
        var link: String? = nil
        var title: String? = nil
    }

    private let fileURL = URL.applicationSupportDirectory.appending(path: "Stow/Shelf.plist")
    /// Bookmarks already made, by item, so saving doesn't rebuild them every time.
    private var bookmarkCache: [UUID: (url: URL, data: Data)] = [:]
    /// Files reopened from bookmarks at launch that Stow is currently accessing, keyed
    /// by the file's (standardized) URL, so access can be given up once they leave
    /// the shelf.
    private var accessedFiles: [URL: URL] = [:]

    func save(_ items: [ShelfItem]) {
        let records = items.compactMap(record(for:))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Stow: couldn't save the shelf: \(error.localizedDescription)")
        }
        let ids = Set(items.map { $0.id })
        bookmarkCache = bookmarkCache.filter { ids.contains($0.key) }

        let onShelf = Set(items.compactMap { $0.fileURL })
        for (url, accessed) in accessedFiles where !onShelf.contains(url) {
            accessed.stopAccessingSecurityScopedResource()
            accessedFiles[url] = nil
        }
    }

    func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? PropertyListDecoder().decode([Record].self, from: data)
        else { return [] }
        return records.compactMap(item(from:))
    }

    private func record(for item: ShelfItem) -> Record? {
        switch item.content {
        case .file(let url):
            guard let bookmark = bookmark(for: item.id, url: url) else { return nil }
            return Record(id: item.id, kind: .file, bookmark: bookmark)
        case .text(let text):
            return Record(id: item.id, kind: .text, text: text)
        case .link(let url, let title):
            return Record(id: item.id, kind: .link, link: url.absoluteString, title: title)
        }
    }

    private func bookmark(for id: UUID, url: URL) -> Data? {
        if let cached = bookmarkCache[id], cached.url == url {
            return cached.data
        }
        guard let data = try? url.bookmarkData(options: .withSecurityScope) else { return nil }
        bookmarkCache[id] = (url, data)
        return data
    }

    private func item(from record: Record) -> ShelfItem? {
        switch record.kind {
        case .file:
            guard let bookmark = record.bookmark else { return nil }
            // `isStale` means the file moved and the bookmark should be remade; the
            // next save does that, since stale bookmarks aren't cached.
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            let url = resolved.standardizedFileURL
            // Start using the permission the bookmark carries. Until then the sandbox
            // won't even say whether the file exists.
            let accessing = resolved.startAccessingSecurityScopedResource()
            let inTrash = url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
            guard FileManager.default.fileExists(atPath: url.path), !inTrash else {
                if accessing {
                    resolved.stopAccessingSecurityScopedResource()
                }
                return nil
            }
            if accessing {
                accessedFiles[url] = resolved
            }
            if !isStale {
                bookmarkCache[record.id] = (url, bookmark)
            }
            return ShelfItem(id: record.id, content: .file(url), isStowCopy: PromisedFileStore().owns(url))
        case .text:
            guard let text = record.text else { return nil }
            return ShelfItem(id: record.id, content: .text(text))
        case .link:
            guard let string = record.link, let url = URL(string: string) else { return nil }
            return ShelfItem(id: record.id, content: .link(url, title: record.title))
        }
    }
}

/// Saves the shelf every time its items change, the same way ShelfViewController
/// keeps its list in sync (see its `observeItems()`).
final class ShelfAutosave {
    private let viewModel: ShelfViewModel
    private let archive: ShelfArchive

    init(viewModel: ShelfViewModel, archive: ShelfArchive) {
        self.viewModel = viewModel
        self.archive = archive
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = viewModel.items
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.archive.save(self.viewModel.items)
                self.observe()
            }
        }
    }
}
