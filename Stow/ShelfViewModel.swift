import AppKit
import Observation

/// The single source of truth for what's on the shelf. Views read `items` and ask
/// the view model to change them; nothing else keeps its own copy of the list.
@Observable
final class ShelfViewModel {
    private(set) var items: [ShelfItem] = []

    /// Remove items once they've been dragged out and dropped somewhere.
    /// Phase 4 moves this into the Settings window.
    var removeAfterDrag = true

    /// File promises that were dropped on the shelf but whose files haven't been
    /// written yet, keyed by drop, with how many files each drop is still waiting for.
    private var pendingPromises: [UUID: Int] = [:]

    /// True while a promised file is still on its way. Used so the shelf doesn't hide
    /// itself as "empty" a moment before the file lands.
    var isReceivingPromises: Bool { !pendingPromises.isEmpty }

    @ObservationIgnored private let promisedFiles = PromisedFileStore()

    /// File promises call back on this queue once the source app has written the file.
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: - Adding

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
        items.append(ShelfItem(content: .file(fileURL.standardizedFileURL), isPromisedCopy: true))
    }

    // MARK: - Removing

    /// Removes items (the right-click "Remove" command). Stow's own promised copies go
    /// to the Trash; files that live elsewhere are never touched.
    func remove(_ ids: Set<ShelfItem.ID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        trashPromisedCopies(of: removed, after: .zero)
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
        guard moved || removeAfterDrag else { return }

        let ids = Set(ids)
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        // The app it was dropped into may read the file lazily (a browser upload
        // form, for example), so wait before moving Stow's copy to the Trash.
        trashPromisedCopies(of: removed, after: .seconds(600))
    }

    /// Trashes files left in the Promised folder by earlier runs. Nothing is saved
    /// across launches yet (that's Phase 4), so at launch every one of them is an orphan.
    func trashLeftoverPromisedFiles() {
        promisedFiles.trashAll()
    }

    private func trashPromisedCopies(of removed: [ShelfItem], after delay: Duration) {
        let urls = removed.filter { $0.isPromisedCopy }.compactMap { $0.fileURL }
        guard !urls.isEmpty else { return }
        let store = promisedFiles
        Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            store.trash(urls)
        }
    }
}
