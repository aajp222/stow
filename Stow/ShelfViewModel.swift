import AppKit
import Observation

/// The single source of truth for what's on the shelf. Views read `items` and ask
/// the view model to change them; nothing else keeps its own copy of the list.
@Observable
final class ShelfViewModel {
    private(set) var items: [ShelfItem] = []

    @ObservationIgnored private let settings: AppSettings

    /// File promises that were dropped on the shelf but whose files haven't been
    /// written yet, keyed by drop, with how many files each drop is still waiting for.
    private var pendingPromises: [UUID: Int] = [:]

    /// True while a promised file is still on its way. Used so the shelf doesn't hide
    /// itself as "empty" a moment before the file lands.
    var isReceivingPromises: Bool { !pendingPromises.isEmpty }

    /// The items taken off the shelf most recently, for Restore Last Removed Files.
    private(set) var lastRemoved: [ShelfItem] = []
    /// Where trashed Stow copies went in the Trash, so a restore can put them back.
    @ObservationIgnored private var trashedCopies: [URL: URL] = [:]

    @ObservationIgnored private let promisedFiles = PromisedFileStore()

    /// File promises call back on this queue once the source app has written the file.
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Adding

    /// Puts back the shelf saved at the last quit (see ShelfArchive).
    func loadSaved(_ saved: [ShelfItem]) {
        items = saved
    }

    /// Adds whatever was dropped or pasted. Files are added as references, file
    /// promises are received, links and text become items of their own, and images
    /// are saved as PNG files in Stow's folder.
    func add(_ incoming: [IncomingItem]) {
        var files: [URL] = []
        var promises: [NSFilePromiseReceiver] = []
        var newItems: [ShelfItem] = []
        var links = Set(items.compactMap { item -> URL? in
            if case .link(let url, _) = item.content { url } else { nil }
        })
        var texts = Set(items.compactMap { item -> String? in
            if case .text(let text) = item.content { text } else { nil }
        })
        for thing in incoming {
            switch thing {
            case .file(let url):
                files.append(url)
            case .promise(let promise):
                promises.append(promise)
            case .link(let url, let title):
                if links.insert(url).inserted {
                    newItems.append(ShelfItem(content: .link(url, title: title)))
                }
            case .text(let text):
                if texts.insert(text).inserted {
                    newItems.append(ShelfItem(content: .text(text)))
                }
            case .image(let png):
                if let item = saveImage(png) {
                    newItems.append(item)
                }
            }
        }
        addFiles(files)
        receive(promises)
        items += newItems
    }

    /// Adds references to files and folders. Anything already on the shelf is skipped.
    func addFiles(_ urls: [URL]) {
        var seen = Set(items.compactMap { $0.fileURL?.standardizedFileURL })
        var newItems: [ShelfItem] = []
        for url in urls {
            let url = url.standardizedFileURL
            guard seen.insert(url).inserted else { continue }
            newItems.append(ShelfItem(content: .file(url)))
        }
        items += newItems
    }

    /// Receives dropped file promises.
    ///
    /// A file promise is a drag that says "I'll create this file wherever you want
    /// it" instead of pointing at a file that already exists. Screenshot thumbnails,
    /// Photos and Mail attachments drag this way. We pick a destination folder, the
    /// source app writes the file there, and the reader block below runs once per
    /// file when it's done.
    func receive(_ promises: [NSFilePromiseReceiver]) {
        for promise in promises {
            let folder: URL
            do {
                folder = try promisedFiles.makeDropFolder()
            } catch {
                NSLog("Stow: couldn't create a folder for a promised file: \(error.localizedDescription)")
                continue
            }

            let drop = UUID()
            pendingPromises[drop] = max(promise.fileNames.count, 1)
            // Safety net: if the source app never delivers, stop waiting after 30 s so
            // the shelf can still hide itself.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.pendingPromises[drop] = nil
            }

            // The reader block runs on `promiseQueue`, not the main thread, so it's
            // marked @Sendable and hops back to the main actor before touching `items`.
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { @Sendable [weak self] fileURL, error in
                Task { @MainActor [weak self] in
                    self?.promisedFileArrived(fileURL, error: error, drop: drop)
                }
            }
        }
    }

    private func promisedFileArrived(_ fileURL: URL, error: Error?, drop: UUID) {
        if let remaining = pendingPromises[drop] {
            pendingPromises[drop] = remaining > 1 ? remaining - 1 : nil
        }
        if let error {
            NSLog("Stow: a promised file didn't arrive: \(error.localizedDescription)")
            return
        }
        items.append(ShelfItem(content: .file(fileURL.standardizedFileURL), isStowCopy: true))
    }

    /// "Add Clipboard Contents to Stow": adds whatever is on the clipboard, the same
    /// way as a drop. Returns false if there was nothing usable on it.
    @discardableResult
    func addClipboardContents() -> Bool {
        let incoming = PasteboardContents.read(from: .general)
        guard !incoming.isEmpty else { return false }
        add(incoming)
        return true
    }

    /// Saves an image that isn't a file yet (image data from a drag or the clipboard)
    /// as a PNG in Stow's folder, so it can be dragged out anywhere a file can.
    private func saveImage(_ png: Data) -> ShelfItem? {
        do {
            let url = try promisedFiles.makeDropFolder().appending(path: "Image.png")
            try png.write(to: url)
            return ShelfItem(content: .file(url.standardizedFileURL), isStowCopy: true)
        } catch {
            NSLog("Stow: couldn't save an image: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Renaming and moving

    /// Renames the item's file on disk (it's the real file, not just a label) and
    /// keeps the item pointing at it.
    func rename(_ id: ShelfItem.ID, to newName: String) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), let url = items[index].fileURL else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != url.lastPathComponent else { return }
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
            throw ShelfError.invalidName(name)
        }
        let destination = url.deletingLastPathComponent().appending(path: name).standardizedFileURL
        // A change of capitalisation only is the same path on a case-insensitive disk.
        let caseOnly = destination.path.lowercased() == url.path.lowercased()
        guard caseOnly || !FileManager.default.fileExists(atPath: destination.path) else {
            throw ShelfError.alreadyExists(name: name, folder: url.deletingLastPathComponent().lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        items[index] = items[index].relocated(to: destination, isStowCopy: items[index].isStowCopy)
    }

    /// Moves items' files into `folder` and keeps the items pointing at them.
    /// Returns a message for each file that couldn't be moved.
    func move(_ ids: [ShelfItem.ID], to folder: URL) -> [String] {
        var problems: [String] = []
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }), let url = items[index].fileURL else { continue }
            let destination = folder.appending(path: url.lastPathComponent).standardizedFileURL
            guard destination != url else { continue }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                problems.append(ShelfError.alreadyExists(name: url.lastPathComponent, folder: folder.lastPathComponent).localizedDescription)
                continue
            }
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                // A Stow copy moved out of Stow's folder is yours now: Stow won't trash it.
                items[index] = items[index].relocated(to: destination, isStowCopy: promisedFiles.owns(destination))
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        return problems
    }

    // MARK: - Removing

    /// Removes items (the right-click "Remove" command). Stow's own promised copies go
    /// to the Trash; files that live elsewhere are never touched.
    func remove(_ ids: Set<ShelfItem.ID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        rememberRemoved(removed)
        trashStowCopies(of: removed, after: .zero)
    }

    func clear() {
        remove(Set(items.map { $0.id }))
    }

    /// Called when a drag *out of* the shelf finishes.
    ///
    /// `operation` is what the drop target actually did: empty if the drag was
    /// cancelled or the target refused it, in which case nothing is removed.
    func finishDragOut(of ids: [ShelfItem.ID], operation: NSDragOperation) {
        guard !operation.isEmpty else { return }
        // The shelf only offers "move" while ⌘ is held (see ShelfCollectionView).
        // After a move the file is no longer where our reference points, so the item
        // has to go whatever the setting says.
        let moved = !operation.isDisjoint(with: [.move, .generic])
        guard moved || settings.removeAfterDrag else { return }

        let ids = Set(ids)
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        rememberRemoved(removed)
        // The app it was dropped into may read the file lazily (a browser upload
        // form, for example), so wait before moving Stow's copy to the Trash.
        trashStowCopies(of: removed, after: .seconds(600))
    }

    // MARK: - Restoring

    /// Whether there's something for Restore Last Removed Files to bring back.
    var canRestoreLastRemoved: Bool { !lastRemoved.isEmpty }

    /// Puts back the items taken off the shelf most recently (by one Remove, Clear,
    /// or drag out). Stow copies that were already trashed come back out of the
    /// Trash. Items whose files have since been moved or deleted are skipped.
    func restoreLastRemoved() {
        let fileManager = FileManager.default
        let onShelfIDs = Set(items.map { $0.id })
        var onShelf = Set(items.compactMap { $0.fileURL })
        var restored: [ShelfItem] = []
        for item in lastRemoved where !onShelfIDs.contains(item.id) {
            // Text and links have no file to check.
            guard let url = item.fileURL else {
                restored.append(item)
                continue
            }
            guard !onShelf.contains(url) else { continue }
            if !fileManager.fileExists(atPath: url.path), let locationInTrash = trashedCopies[url] {
                do {
                    try promisedFiles.putBack(locationInTrash, at: url)
                } catch {
                    NSLog("Stow: couldn't restore \(url.lastPathComponent) from the Trash: \(error.localizedDescription)")
                }
            }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            onShelf.insert(url)
            restored.append(item)
        }
        lastRemoved = []
        trashedCopies = [:]
        items += restored
    }

    private func rememberRemoved(_ removed: [ShelfItem]) {
        guard !removed.isEmpty else { return }
        lastRemoved = removed
        // Only the latest batch can be restored, so forget older Trash locations.
        let urls = Set(removed.compactMap { $0.fileURL })
        trashedCopies = trashedCopies.filter { urls.contains($0.key) }
    }

    /// Trashes files left in Stow's folder by earlier runs, except the ones still on
    /// the (just loaded) shelf.
    func trashLeftoverPromisedFiles() {
        let stillOnShelf = Set(items.filter { $0.isStowCopy }.compactMap { $0.fileURL })
        promisedFiles.trashAll(except: stillOnShelf)
    }

    private func trashStowCopies(of removed: [ShelfItem], after delay: Duration) {
        let urls = removed.filter { $0.isStowCopy }.compactMap { $0.fileURL }
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self else { return }
            // Skip anything that was restored onto the shelf in the meantime.
            let onShelf = Set(self.items.compactMap { $0.fileURL })
            let trashed = self.promisedFiles.trash(urls.filter { !onShelf.contains($0) })
            self.trashedCopies.merge(trashed) { _, new in new }
        }
    }
}

/// Problems renaming or moving a file, worded for an alert.
enum ShelfError: LocalizedError {
    case invalidName(String)
    case alreadyExists(name: String, folder: String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            name.isEmpty ? "The name can't be empty." : "“\(name)” can't be used as a name. Names can't contain “/” or “:”."
        case .alreadyExists(let name, let folder):
            "An item named “\(name)” already exists in “\(folder)”."
        }
    }
}
