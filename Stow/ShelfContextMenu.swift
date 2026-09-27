import AppKit
import UniformTypeIdentifiers

/// Builds the shelf's right-click menus and carries out their commands.
///
/// macOS adds two things itself: "Ask Siri" at the top (macOS 27 puts it in every
/// standard right-click menu) and the Services submenu at the bottom. Services shows
/// up because ShelfCollectionView offers the selected files to it; see its
/// NSServicesMenuRequestor conformance.
final class ShelfContextMenu: NSObject {
    private let viewModel: ShelfViewModel
    /// The items the open menu acts on, captured when the menu was built.
    private var targets: [ShelfItem] = []
    /// Kept alive while its Share… item is on screen.
    private var sharePicker: NSSharingServicePicker?
    /// Folders you've given Stow access to this session (see withFolderAccess).
    private var grantedFolders: [URL] = []

    init(viewModel: ShelfViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    /// The menu for right-clicking `items`, or for empty space on the shelf when
    /// `items` is empty (then only the shelf-wide commands are shown).
    func menu(for items: [ShelfItem]) -> NSMenu {
        targets = items
        let menu = NSMenu()
        // Each item's enabled state is set by hand below.
        menu.autoenablesItems = false

        if !items.isEmpty {
            // File commands only make sense when every selected item is a file.
            let urls = items.compactMap { $0.fileURL }
            let allFiles = urls.count == items.count
            let allLinks = items.allSatisfy { if case .link = $0.content { true } else { false } }

            let openTitle = allLinks ? (items.count == 1 ? "Open Link" : "Open Links") : "Open"
            menu.addItem(makeItem(openTitle, #selector(openItems), enabled: items.contains { Self.canOpen($0) }))
            if allFiles {
                let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                openWith.submenu = makeOpenWithMenu(for: urls)
                menu.addItem(openWith)
            }

            // The standard Share… item; choosing it shows the system share menu.
            let picker = NSSharingServicePicker(items: items.map { $0.shareableValue })
            sharePicker = picker
            menu.addItem(picker.standardShareMenuItem)

            if allFiles {
                let quickActions = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
                quickActions.submenu = makeQuickActionsMenu(for: urls)
                menu.addItem(quickActions)
                menu.addItem(makeItem("Rename…", #selector(renameItem), enabled: urls.count == 1))
                menu.addItem(makeItem("Move…", #selector(moveItems)))
            }
            menu.addItem(makeItem("Copy", #selector(copyItems)))
            if allFiles {
                menu.addItem(makeItem("Show in Finder", #selector(showInFinder)))
            }
            menu.addItem(.separator())
            let allPinned = items.allSatisfy { $0.isPinned }
            menu.addItem(makeItem(allPinned ? "Unpin" : "Pin", allPinned ? #selector(unpinItems) : #selector(pinItems)))
            // Gathering items that are already one whole stack would change nothing.
            let sharedStack = Set(items.map { $0.stackID }).count == 1 ? items[0].stackID : nil
            let isOneStack = sharedStack != nil && stackSize(sharedStack) == items.count
            if items.count >= 2, !isOneStack {
                menu.addItem(makeItem("Stack Items", #selector(stackItems)))
            }
            if isOneStack {
                menu.addItem(makeItem("Rename Stack…", #selector(renameStack)))
            }
            if items.contains(where: { $0.stackID.map { stackSize($0) >= 2 } ?? false }) {
                menu.addItem(makeItem("Unstack", #selector(unstackItems)))
            }
            menu.addItem(makeItem("Remove", #selector(removeItems)))
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Restore Last Removed Files", #selector(restoreLastRemoved), enabled: viewModel.canRestoreLastRemoved))
        menu.addItem(makeItem(
            "Add Clipboard Contents to Stow",
            #selector(addClipboardContents),
            // Checks only what kinds of data are on the clipboard, without reading it.
            enabled: PasteboardContents.offersAcceptedTypes(.general)
        ))
        return menu
    }

    /// How many items on the shelf share a stack ID. A "stack" of one shows as an
    /// ordinary item, so it isn't offered Unstack.
    private func stackSize(_ stackID: UUID?) -> Int {
        viewModel.items.filter { $0.stackID == stackID }.count
    }

    private func makeItem(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    // MARK: - Quick Actions

    /// Makes new files from the selection: a zip, converted or smaller images, or one
    /// PDF. The originals are left alone; each result lands on the shelf next to them.
    private func makeQuickActionsMenu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let images = urls.filter(QuickActions.isImage)
        let allImages = images.count == urls.count
        let pages = urls.filter { QuickActions.isImage($0) || QuickActions.isPDF($0) }

        menu.addItem(makeItem("Compress", #selector(compressItems)))
        menu.addItem(.separator())
        for type in QuickActions.conversionTypes {
            let name = type.preferredFilenameExtension?.uppercased() ?? type.localizedDescription ?? "Image"
            let item = makeItem("Convert to \(name)", #selector(convertItems(_:)), enabled: allImages)
            item.representedObject = type.identifier
            menu.addItem(item)
        }
        menu.addItem(makeItem("Make Smaller", #selector(makeItemsSmaller), enabled: allImages))
        menu.addItem(.separator())
        menu.addItem(makeItem("Combine into PDF", #selector(combineIntoPDF), enabled: pages.count == urls.count && !pages.isEmpty))
        return menu
    }

    @objc private func compressItems() {
        let urls = targets.compactMap { $0.fileURL }
        runQuickAction("Couldn't compress the items") { folder in
            [try QuickActions.compress(urls, into: folder)]
        }
    }

    @objc private func convertItems(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, let type = UTType(identifier) else { return }
        let urls = targets.compactMap { $0.fileURL }
        runQuickAction("Couldn't convert the images") { folder in
            try urls.map { try QuickActions.convert($0, to: type, into: folder) }
        }
    }

    @objc private func makeItemsSmaller() {
        let urls = targets.compactMap { $0.fileURL }
        runQuickAction("Couldn't make the images smaller") { folder in
            try urls.map { try QuickActions.makeSmaller($0, into: folder) }
        }
    }

    @objc private func combineIntoPDF() {
        let urls = targets.compactMap { $0.fileURL }
        runQuickAction("Couldn't combine the items into a PDF") { folder in
            [try QuickActions.combineIntoPDF(urls, into: folder)]
        }
    }

    /// Runs a quick action on a background thread and puts what it made on the shelf,
    /// after the last of the items it was made from. Results go in a fresh folder in
    /// Stow's own storage, so they're Stow copies: cleaned up once removed.
    private func runQuickAction(_ failureTitle: String, _ work: @escaping @Sendable (URL) throws -> [URL]) {
        let anchor = targets.last?.id
        let folder: URL
        do {
            folder = try PromisedFileStore().makeDropFolder()
        } catch {
            Dialog.showProblem(failureTitle, details: error.localizedDescription)
            return
        }
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) { try work(folder) }.value
                viewModel.addStowCopies(results, after: anchor)
            } catch {
                Dialog.showProblem(failureTitle, details: error.localizedDescription)
            }
        }
    }

    // MARK: - Open With

    /// Apps that can open every selected file, like Finder's Open With: the default
    /// app first, then the rest alphabetically, then Other….
    private func makeOpenWithMenu(for urls: [URL]) -> NSMenu {
        let workspace = NSWorkspace.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        var apps = workspace.urlsForApplications(toOpen: urls[0])
        for url in urls.dropFirst() {
            let alsoOpens = Set(workspace.urlsForApplications(toOpen: url))
            apps = apps.filter { alsoOpens.contains($0) }
        }
        let defaultApp = workspace.urlForApplication(toOpen: urls[0]).flatMap { apps.contains($0) ? $0 : nil }
        if let defaultApp {
            menu.addItem(makeOpenWithItem(for: defaultApp, suffix: " (default)"))
            menu.addItem(.separator())
        }
        let otherApps = apps
            .filter { $0 != defaultApp }
            .sorted { Self.appName($0).localizedStandardCompare(Self.appName($1)) == .orderedAscending }
        for app in otherApps {
            menu.addItem(makeOpenWithItem(for: app))
        }
        if !otherApps.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Other…", #selector(openWithOtherApp)))
        return menu
    }

    private func makeOpenWithItem(for app: URL, suffix: String = "") -> NSMenuItem {
        let item = makeItem(Self.appName(app) + suffix, #selector(openWithApp(_:)))
        item.representedObject = app
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    private static func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        open(with: app)
    }

    @objc private func openWithOtherApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an app to open the file with."
        guard Dialog.run({ panel.runModal() }) == .OK, let app = panel.url else { return }
        open(with: app)
    }

    private func open(with app: URL) {
        let urls = targets.compactMap { $0.fileURL }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    // MARK: - File commands

    /// Renames the file on disk, not just the shelf item.
    @objc private func renameItem() {
        guard targets.count == 1, let item = targets.first, let url = item.fileURL else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(url.lastPathComponent)”"
        alert.informativeText = "This renames the file itself, wherever it is on your Mac."
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard Dialog.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        let folder = url.deletingLastPathComponent()
        do {
            try withFolderAccess(
                to: folder,
                reason: "To rename “\(url.lastPathComponent)”, Stow needs access to the folder it's in, “\(folder.lastPathComponent)”. Click Allow."
            ) {
                try viewModel.rename(item.id, to: field.stringValue)
            }
        } catch is CancellationError {
            return
        } catch {
            Dialog.showProblem("Couldn't rename “\(url.lastPathComponent)”", details: error.localizedDescription)
        }
    }

    @objc private func moveItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = targets.count == 1
            ? "Choose where to move “\(targets[0].displayName)”."
            : "Choose where to move \(targets.count) items."
        guard Dialog.run({ panel.runModal() }) == .OK, let destination = panel.url else { return }
        var problems: [String] = []
        for item in targets {
            guard let url = item.fileURL else { continue }
            let folder = url.deletingLastPathComponent()
            do {
                try withFolderAccess(
                    to: folder,
                    reason: "To move “\(url.lastPathComponent)”, Stow needs access to the folder it's in, “\(folder.lastPathComponent)”. Click Allow."
                ) {
                    try viewModel.move(item.id, to: destination)
                }
            } catch is CancellationError {
                continue
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty {
            Dialog.showProblem("Some items couldn't be moved", details: problems.joined(separator: "\n"))
        }
    }

    // MARK: - Folder access

    /// Runs `operation`, and if the App Sandbox refuses it for lack of access to
    /// `folder`, asks you to grant access to that folder and tries once more.
    ///
    /// Dropping a file on the shelf gives Stow access to that file only. Renaming or
    /// moving it also changes the folder it's in, and the sandbox won't allow that
    /// until you pick the folder in an Open panel yourself. Stow keeps that access for
    /// the rest of the session, so it asks at most once per folder. Throws
    /// CancellationError if you click Cancel.
    private func withFolderAccess(to folder: URL, reason: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error where Self.isPermissionError(error) {
            let panel = NSOpenPanel()
            panel.message = reason
            panel.prompt = "Allow"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = folder
            guard Dialog.run({ panel.runModal() }) == .OK, let granted = panel.url else {
                throw CancellationError()
            }
            if granted.startAccessingSecurityScopedResource() {
                grantedFolders.append(granted)
            }
            try operation()
        }
    }

    /// Whether `error` means "not allowed" (the sandbox, or ordinary file permissions)
    /// rather than something like a name clash.
    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        let permissionCodes = [Int(EPERM), Int(EACCES)]
        if error.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, permissionCodes.contains(error.code) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, permissionCodes.contains(underlying.code) {
            return true
        }
        return false
    }

    @objc private func copyItems() {
        Self.copy(targets)
    }

    @objc private func openItems() {
        if !Self.open(targets) {
            NSSound.beep()
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(targets.compactMap { $0.fileURL })
    }

    @objc private func pinItems() {
        viewModel.setPinned(Set(targets.map { $0.id }), true)
    }

    @objc private func unpinItems() {
        viewModel.setPinned(Set(targets.map { $0.id }), false)
    }

    /// Names a stack, like "Tax docs". The name shows instead of "5 items".
    @objc private func renameStack() {
        guard let stackID = targets.first?.stackID else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Stack"
        alert.informativeText = "Leave it empty to show the number of items instead."
        let field = NSTextField(string: targets.first?.stackName ?? "")
        field.placeholderString = "\(targets.count) items"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard Dialog.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        viewModel.renameStack(stackID, to: field.stringValue)
    }

    @objc private func stackItems() {
        viewModel.stack(targets.map { $0.id })
    }

    @objc private func unstackItems() {
        viewModel.unstack(targets.map { $0.id })
    }

    @objc private func removeItems() {
        viewModel.remove(Set(targets.map { $0.id }))
    }

    // MARK: - Shared with the keyboard

    /// Puts the items on the clipboard, like ⌘C in Finder: paste files into a Finder
    /// window to copy them there or into Mail to attach them; paste text or a link
    /// anywhere you can type.
    static func copy(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { $0.pasteboardWriter })
    }

    /// Opens files in their default apps and links in the browser, like double-clicking
    /// them in Finder. Text has nothing to open it with. Returns false if nothing opened.
    @discardableResult
    static func open(_ items: [ShelfItem]) -> Bool {
        var opened = false
        for item in items {
            switch item.content {
            case .file(let url), .link(let url, _):
                opened = NSWorkspace.shared.open(url) || opened
            case .text:
                continue
            }
        }
        return opened
    }

    private static func canOpen(_ item: ShelfItem) -> Bool {
        if case .text = item.content { false } else { true }
    }

    // MARK: - Shelf commands

    @objc private func restoreLastRemoved() {
        viewModel.restoreLastRemoved()
    }

    @objc private func addClipboardContents() {
        if !viewModel.addClipboardContents() {
            NSSound.beep()
        }
    }
}
