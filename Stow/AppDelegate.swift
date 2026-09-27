import AppKit
import Carbon.HIToolbox

/// Entry point. Stow is a plain AppKit app with no SwiftUI `App` and no storyboard,
/// so we create the application and its delegate ourselves.
@main
struct StowMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        // `NSApplication.delegate` is a weak reference, so keep our own strong
        // reference alive for as long as the run loop runs.
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

/// Owns the menu bar icon, the shelf, and the pieces that connect them.
///
/// There is no Dock icon and no main window: `INFOPLIST_KEY_LSUIElement = YES` in the
/// target's build settings writes `LSUIElement` into the generated Info.plist, which
/// makes macOS treat Stow as an "agent" app.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private lazy var viewModel = ShelfViewModel(settings: settings)
    private lazy var shelf = ShelfPanelController(viewModel: viewModel, settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings)
    private let dragMonitor = DragMonitor()
    private var autosave: ShelfAutosave?
    private var hotKey: HotKey?

    private var statusItem: NSStatusItem?
    private var toggleShelfItem: NSMenuItem?
    private var clearShelfItem: NSMenuItem?
    private var resetPositionItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Put back what was on the shelf at the last quit, then clean up Stow's own
        // copies that are no longer on it, and save from now on.
        let archive = ShelfArchive()
        viewModel.loadSaved(archive.load())
        viewModel.trashLeftoverPromisedFiles()
        autosave = ShelfAutosave(viewModel: viewModel, archive: archive)

        setUpStatusItem()
        // Tell AppKit that Stow can hand file URLs to services, so right-clicking
        // shelf items gets a Services submenu (see ShelfCollectionView).
        NSApp.registerServicesMenuSendTypes([.fileURL], returnTypes: [])

        dragMonitor.onDragBegan = { [weak self] point in self?.shelf.dragBegan(at: point) }
        dragMonitor.onDragEnded = { [weak self] in self?.shelf.dragEnded() }
        dragMonitor.waitsForScreenEdge = { [weak self] in self?.settings.showOnlyAtScreenEdge ?? false }
        dragMonitor.start()

        // ⌃⌥S shows or hides the shelf from anywhere.
        hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) { [weak self] in
            self?.shelf.toggle()
        }
        if hotKey == nil {
            NSLog("Stow: couldn't register ⌃⌥S; another app may be using it.")
        }

        // A shelf with items stays on screen, so bring it back after a relaunch.
        if !viewModel.items.isEmpty {
            shelf.show(on: ShelfPanelController.screenWithMouse())
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // SF Symbols are template images, so the icon adapts to light/dark menu bars.
        item.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Stow")

        let menu = NSMenu()
        menu.delegate = self
        // We set each item's enabled state ourselves in menuNeedsUpdate.
        menu.autoenablesItems = false

        let toggle = makeItem("Show Shelf", action: #selector(toggleShelf))
        menu.addItem(toggle)
        let resetPosition = makeItem("Reset Shelf Position", action: #selector(resetShelfPosition))
        menu.addItem(resetPosition)
        let clear = makeItem("Clear Shelf", action: #selector(clearShelf))
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", action: #selector(showSettings), keyEquivalent: ","))
        let quit = NSMenuItem(title: "Quit Stow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        toggleShelfItem = toggle
        clearShelfItem = clear
        resetPositionItem = resetPosition
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    /// Called just before the menu opens, so its titles always match the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleShelfItem?.title = shelf.isShown ? "Hide Shelf" : "Show Shelf"
        clearShelfItem?.isEnabled = !viewModel.items.isEmpty
        resetPositionItem?.isEnabled = shelf.hasCustomPlacement
    }

    // MARK: - Actions

    @objc private func toggleShelf() {
        shelf.toggle()
    }

    /// Forget where the shelf was dragged to and go back to the screen edge.
    @objc private func resetShelfPosition() {
        shelf.resetPlacement()
    }

    @objc private func clearShelf() {
        viewModel.clear()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }
}
