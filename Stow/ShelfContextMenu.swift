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

        let urls = items.compactMap { $0.fileURL }
        if !urls.isEmpty {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = makeOpenWithMenu(for: urls)
            menu.addItem(openWith)

            // The standard Share… item; choosing it shows the system share menu.
            let picker = NSSharingServicePicker(items: urls)
            sharePicker = picker
            menu.addItem(picker.standardShareMenuItem)

            menu.addItem(makeItem("Rename…", #selector(renameItem), enabled: urls.count == 1))
            menu.addItem(makeItem("Move…", #selector(moveItems)))
            menu.addItem(makeItem("Copy", #selector(copyFiles)))
            menu.addItem(makeItem("Show in Finder", #selector(showInFinder)))
            menu.addItem(.separator())
            menu.addItem(makeItem("Remove", #selector(removeItems)))
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Restore Last Removed Files", #selector(restoreLastRemoved), enabled: viewModel.canRestoreLastRemoved))
        menu.addItem(makeItem("Add Clipboard Contents to Stow", #selector(addClipboardContents), enabled: ClipboardContents.isAvailable()))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
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
        guard Self.runModal({ panel.runModal() }) == .OK, let app = panel.url else { return }
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
        guard Self.runModal({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        do {
            try viewModel.rename(item.id, to: field.stringValue)
        } catch {
            Self.showProblem("Couldn't rename “\(url.lastPathComponent)”", details: error.localizedDescription)
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
        guard Self.runModal({ panel.runModal() }) == .OK, let folder = panel.url else { return }
        let problems = viewModel.move(targets.map { $0.id }, to: folder)
        if !problems.isEmpty {
            Self.showProblem("Some items couldn't be moved", details: problems.joined(separator: "\n"))
        }
    }

    /// Puts the files on the clipboard, like ⌘C in Finder: paste into a Finder
    /// window to copy them there, or into Mail to attach them.
    @objc private func copyFiles() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(targets.compactMap { $0.fileURL as NSURL? })
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(targets.compactMap { $0.fileURL })
    }

    @objc private func removeItems() {
        viewModel.remove(Set(targets.map { $0.id }))
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

    // MARK: - Dialogs

    /// Runs a dialog. Stow is normally never the active app, but you can only type
    /// into a dialog in the active app, so activate Stow for the dialog, then give
    /// activation back to the app you were using.
    private static func runModal<Result>(_ body: () -> Result) -> Result {
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        let result = body()
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(from: .current, options: [])
        }
        return result
    }

    private static func showProblem(_ title: String, details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        _ = runModal { alert.runModal() }
    }
}
