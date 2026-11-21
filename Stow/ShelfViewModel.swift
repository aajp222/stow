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
    /// When `lastRemoved` was taken off the shelf.
    @ObservationIgnored private var lastRemovedAt = Date.distantPast

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
        // Two or more files dropped at once become one stack (if that setting is on).
        // Promised files arrive later and join the same stack as they land.
        let fileCount = files.count + promises.reduce(0) { $0 + max($1.fileNames.count, 1) }
        let stackID = settings.stackDroppedFiles && fileCount >= 2 ? UUID() : nil
        addFiles(files, stackID: stackID)
        receive(promises, stackID: stackID)
        items += newItems
    }

    /// Adds references to files and folders. Anything already on the shelf is skipped.
    /// Files already in Stow's own storage (shared through the Share menu, say) are
    /// Stow copies.
    func addFiles(_ urls: [URL], stackID: UUID? = nil) {
        var seen = Set(items.compactMap { $0.fileURL?.standardizedFileURL })
        var newItems: [ShelfItem] = []
        for url in urls {
            let url = url.standardizedFileURL
            guard seen.insert(url).inserted else { continue }
            newItems.append(ShelfItem(content: .file(url), isStowCopy: promisedFiles.owns(url), stackID: stackID))
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
    func receive(_ promises: [NSFilePromiseReceiver], stackID: UUID? = nil) {
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
                    self?.promisedFileArrived(fileURL, error: error, drop: drop, stackID: stackID)
                }
            }
        }
    }

    private func promisedFileArrived(_ fileURL: URL, error: Error?, drop: UUID, stackID: UUID?) {
        if let remaining = pendingPromises[drop] {
            pendingPromises[drop] = remaining > 1 ? remaining - 1 : nil
        }
        if let error {
            NSLog("Stow: a promised file didn't arrive: \(error.localizedDescription)")
            return
        }
        var item = ShelfItem(content: .file(fileURL.standardizedFileURL), isStowCopy: true, stackID: stackID)
        // Join the rest of its stack, if it's part of one that's still on the shelf.
        if let stackID, let last = items.lastIndex(where: { $0.stackID == stackID }) {
            item.stackName = items[last].stackName
            items.insert(item, at: last + 1)
        } else {
            items.append(item)
        }
    }

    /// Adds files Stow just made (by a quick action, say) just after `anchorID`'s item,
    /// or after its whole stack, or at the end.
    @discardableResult
    func addStowCopies(_ urls: [URL], after anchorID: ShelfItem.ID?) -> [ShelfItem.ID] {
        let newItems = urls.map { ShelfItem(content: .file($0.standardizedFileURL), isStowCopy: true) }
        var index = items.endIndex
        if let anchorID, let anchor = items.firstIndex(where: { $0.id == anchorID }) {
            let stackID = items[anchor].stackID
            index = (stackID.flatMap { id in items.lastIndex { $0.stackID == id } } ?? anchor) + 1
        }
        items.insert(contentsOf: newItems, at: index)
        return newItems.map(\.id)
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

    /// Adds a text item (text read out of an image, say) just after `anchorID`'s item.
    @discardableResult
    func addText(_ text: String, after anchorID: ShelfItem.ID?) -> ShelfItem.ID {
        let item = ShelfItem(content: .text(text))
        var index = items.endIndex
        if let anchorID, let anchor = items.firstIndex(where: { $0.id == anchorID }) {
            let stackID = items[anchor].stackID
            index = (stackID.flatMap { id in items.lastIndex { $0.stackID == id } } ?? anchor) + 1
        }
        items.insert(item, at: index)
        return item.id
    }

    // MARK: - Clipboard history

    /// The stack that holds clipboard history. The same ID every launch, so the
    /// stack carries on after a relaunch.
    static let clipboardStackID = UUID(uuidString: "C1B0A2D0-5704-4C1B-9B0A-2D05704C1B0A")!
    static let clipboardStackName = "Clipboard"

    /// Puts something you just copied at the top of the Clipboard stack, unless it's
    /// the same as the newest entry, and lets the oldest entries go once there are
    /// more than `limit`. The stack is made at the end of the shelf the first time.
    func addClipboardEntries(_ incoming: [IncomingItem], limit: Int) {
        let stackID = Self.clipboardStackID
        var entries: [ShelfItem] = []
        for thing in incoming {
            let content: ShelfItem.Content
            var isStowCopy = false
            switch thing {
            case .file(let url):
                content = .file(url.standardizedFileURL)
                isStowCopy = promisedFiles.owns(url)
            case .link(let url, let title):
                content = .link(url, title: title)
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                content = .text(text)
            case .image(let png):
                guard let saved = saveImage(png), case .file(let url) = saved.content else { continue }
                content = .file(url)
                isStowCopy = true
            case .promise:
                continue
            }
            var item = ShelfItem(content: content, isStowCopy: isStowCopy, stackID: stackID)
            item.stackName = Self.clipboardStackName
            entries.append(item)
        }
        let members = items.filter { $0.stackID == stackID }
        // Copying the same thing twice in a row doesn't add it again.
        if let newest = members.first, entries.count == 1, Self.sameContent(newest.content, entries[0].content) {
            return
        }
        guard !entries.isEmpty else { return }
        let start = items.firstIndex { $0.stackID == stackID } ?? items.endIndex
        items.insert(contentsOf: entries, at: start)

        // Oldest last; pinned entries never count against the limit or go.
        let all = items.filter { $0.stackID == stackID && !$0.isPinned }
        guard all.count > limit else { return }
        let dropped = all.suffix(all.count - limit)
        let droppedIDs = Set(dropped.map(\.id))
        items.removeAll { droppedIDs.contains($0.id) }
        promisedFiles.trash(dropped.filter(\.isStowCopy).compactMap(\.fileURL))
    }

    private static func sameContent(_ a: ShelfItem.Content, _ b: ShelfItem.Content) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): x == y
        case (.link(let x, _), .link(let y, _)): x == y
        case (.file(let x), .file(let y)): x.standardizedFileURL == y.standardizedFileURL
        default: false
        }
    }

    // MARK: - Renaming and moving

    /// Points items at their files' new places after Batch Rename renamed them.
    func relocate(_ ids: [ShelfItem.ID], to urls: [URL]) {
        for (id, url) in zip(ids, urls) {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            items[index] = items[index].relocated(to: url.standardizedFileURL, isStowCopy: items[index].isStowCopy)
        }
    }

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

    /// Moves an item's file into `folder` and keeps the item pointing at it.
    func move(_ id: ShelfItem.ID, to folder: URL) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), let url = items[index].fileURL else { return }
        let destination = folder.appending(path: url.lastPathComponent).standardizedFileURL
        guard destination != url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ShelfError.alreadyExists(name: url.lastPathComponent, folder: folder.lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        // A Stow copy moved out of Stow's folder is yours now: Stow won't trash it.
        items[index] = items[index].relocated(to: destination, isStowCopy: promisedFiles.owns(destination))
    }

    // MARK: - Arranging

    /// Moves items so they sit just before `targetID` (or at the end when it's nil),
    /// keeping their order. Items in `detached` leave their stack; a whole stack that's
    /// moved stays together.
    func reorder(_ ids: [ShelfItem.ID], before targetID: ShelfItem.ID?, detaching detached: Set<ShelfItem.ID>) {
        let moving = Set(ids)
        var moved = items.filter { moving.contains($0.id) }
        for index in moved.indices where detached.contains(moved[index].id) {
            moved[index].stackID = nil
        }
        var remaining = items.filter { !moving.contains($0.id) }
        let insertAt = targetID.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.endIndex
        remaining.insert(contentsOf: moved, at: insertAt)
        items = Self.gatherStacks(remaining)
    }

    /// Gathers items into one new stack, where the first of them is.
    func stack(_ ids: [ShelfItem.ID]) {
        guard Set(ids).count >= 2 else { return }
        let members = Set(ids)
        let stackID = UUID()
        var updated = items
        for index in updated.indices where members.contains(updated[index].id) {
            updated[index].stackID = stackID
        }
        items = Self.gatherStacks(updated)
    }

    /// Splits items into stacks of `size`, in the order they're on the shelf: 100
    /// items in groups of 20 make 5 stacks. Whatever is left over makes a smaller
    /// last stack (a single leftover item stays loose). Items already in a stack
    /// leave it.
    func stack(_ ids: [ShelfItem.ID], inGroupsOf size: Int) {
        guard size >= 2, Set(ids).count >= 2 else { return }
        let members = Set(ids)
        var updated = items
        var stackID = UUID()
        var filled = 0
        let total = updated.count { members.contains($0.id) }
        var placed = 0
        for index in updated.indices where members.contains(updated[index].id) {
            if filled == size {
                stackID = UUID()
                filled = 0
            }
            // A last group of one isn't a stack.
            let isLoneLeftover = filled == 0 && placed == total - 1
            updated[index].stackID = isLoneLeftover ? nil : stackID
            filled += 1
            placed += 1
        }
        items = Self.gatherStacks(updated)
    }

    /// Names a stack (every member carries the name). An empty name removes it, and
    /// the stack shows its item count again.
    func renameStack(_ stackID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = items
        for index in updated.indices where updated[index].stackID == stackID {
            updated[index].stackName = trimmed.isEmpty ? nil : trimmed
        }
        items = updated
    }

    /// Pins or unpins items (see ShelfItem.isPinned).
    func setPinned(_ ids: Set<ShelfItem.ID>, _ isPinned: Bool) {
        var updated = items
        for index in updated.indices where ids.contains(updated[index].id) {
            updated[index].isPinned = isPinned
        }
        items = updated
    }

    /// Takes items out of their stacks, leaving them where they are.
    func unstack(_ ids: [ShelfItem.ID]) {
        let loose = Set(ids)
        var updated = items
        for index in updated.indices where loose.contains(updated[index].id) {
            updated[index].stackID = nil
        }
        items = Self.gatherStacks(updated)
    }

    /// Keeps each stack's members next to each other, where its first member is. The
    /// shelf shows a stack as one row, which only works if its members are together.
    private static func gatherStacks(_ list: [ShelfItem]) -> [ShelfItem] {
        var result: [ShelfItem] = []
        var placed = Set<UUID>()
        for item in list {
            guard let stackID = item.stackID else {
                result.append(item)
                continue
            }
            if placed.insert(stackID).inserted {
                result += list.filter { $0.stackID == stackID }
            }
        }
        return result
    }

    // MARK: - Removing

    /// Removes items (the right-click "Remove" command). Files that live elsewhere are
    /// never touched; Stow's own copies go to the Trash once they can no longer be
    /// restored (see rememberRemoved).
    func remove(_ ids: Set<ShelfItem.ID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        rememberRemoved(removed)
    }

    /// Clear Shelf: removes everything except pinned items.
    func clear() {
        remove(Set(items.filter { !$0.isPinned }.map { $0.id }))
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

        // Pinned items stay, unless their file was moved away.
        let ids = Set(ids).filter { id in moved || items.first { $0.id == id }?.isPinned != true }
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        rememberRemoved(removed)
    }

    // MARK: - Restoring

    /// Whether there's something for Restore Last Removed Files to bring back.
    var canRestoreLastRemoved: Bool { !lastRemoved.isEmpty }

    /// Puts back the items taken off the shelf most recently (by one Remove, Clear,
    /// or drag out). Items whose files have since been moved or deleted are skipped.
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
            guard !onShelf.contains(url), fileManager.fileExists(atPath: url.path) else { continue }
            onShelf.insert(url)
            restored.append(item)
        }
        lastRemoved = []
        items = Self.gatherStacks(items + restored)
    }

    /// Makes `removed` the batch Restore Last Removed Files brings back.
    ///
    /// Stow's own copies (screenshots, photos, saved images) stay where they are while
    /// they can still be restored. The sandbox won't let Stow take a file back out of
    /// the Trash, so they're only trashed once a newer removal replaces them. Even then
    /// they get 10 minutes: an app they were dragged into may still be reading them
    /// (a browser upload form, for example).
    private func rememberRemoved(_ removed: [ShelfItem]) {
        guard !removed.isEmpty else { return }
        let age = Date().timeIntervalSince(lastRemovedAt)
        trashStowCopies(of: lastRemoved, after: .seconds(max(0, 600 - age)))
        lastRemoved = removed
        lastRemovedAt = Date()
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
            // Skip anything that's on the shelf again, or waiting to be restored.
            let keep = Set((self.items + self.lastRemoved).compactMap { $0.fileURL })
            self.promisedFiles.trash(urls.filter { !keep.contains($0) })
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
