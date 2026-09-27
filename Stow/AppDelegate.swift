import AppKit
import Observation

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
    private lazy var updateChecker = UpdateChecker(settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings, updateChecker: updateChecker)
    private lazy var welcomeWindow = WelcomeWindowController(settings: settings)
    private let dragMonitor = DragMonitor()
    private let screenshotWatcher = ScreenshotWatcher()
    private let shareInbox = ShareInbox()
    private var autosave: ShelfAutosave?
    private var hotKey: HotKey?

    private var statusItem: NSStatusItem?
    private var toggleShelfItem: NSMenuItem?
    private var clearShelfItem: NSMenuItem?
    private var resetPositionItem: NSMenuItem?
    private var updateAvailableItem: NSMenuItem?

    /// True when the app is only hosting the unit tests (StowTests), which exercise
    /// the pieces directly: then the menu bar item, shelf and watchers stay off.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

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

        dragMonitor.onDragBegan = { [weak self] point in
            guard let self else { return }
            // A shake brings the shelf right to the pointer.
            self.shelf.dragBegan(at: point, nearPointer: self.settings.shelfTrigger == .shake)
        }
        dragMonitor.onDragEnded = { [weak self] in self?.shelf.dragEnded() }
        dragMonitor.trigger = { [weak self] in self?.settings.shelfTrigger ?? .anyDrag }
        dragMonitor.start()

        // New screenshots, and things shared from other apps' Share menus, land on
        // the shelf like a drop.
        screenshotWatcher.onScreenshots = { [weak self] urls in self?.stow(urls.map { .file($0) }) }
        observeScreenshotSetting()
        shareInbox.onItems = { [weak self] items in self?.stow(items) }
        shareInbox.start()

        // The keyboard shortcut (⌃⌥S unless you pick another in Settings) shows or
        // hides the shelf from anywhere. Shown this way, the shelf takes the keyboard,
        // so the arrow keys and typing to filter work straight away.
        hotKey = HotKey { [weak self] in
            self?.shelf.toggle(focus: true)
        }
        observeShortcut()

        // A shelf with items stays on screen, so bring it back after a relaunch.
        if !viewModel.items.isEmpty {
            shelf.show(on: ShelfPanelController.screenWithMouse())
        }

        if !settings.hasSeenWelcome {
            welcomeWindow.show()
        }
        updateChecker.checkIfDue()
    }

    /// The Share extension opens stow://inbox to launch Stow when something was
    /// shared while it wasn't running. (While it runs, ShareInbox notices by itself.)
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "stow" }) {
            shareInbox.importPending()
        }
    }

    /// Puts things on the shelf that didn't arrive by a drop, and shows it.
    private func stow(_ items: [IncomingItem]) {
        viewModel.add(items)
        shelf.show(on: ShelfPanelController.screenWithMouse())
    }

    /// Starts or stops watching for screenshots as the setting and the chosen
    /// folder change.
    private func observeScreenshotSetting() {
        let bookmark = withObservationTracking {
            settings.stowScreenshots ? settings.screenshotFolderBookmark : nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeScreenshotSetting()
            }
        }
        screenshotWatcher.watch(bookmark: bookmark)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        // Variable length, so there's room for the item count next to the icon.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        // We set each item's enabled state ourselves in menuNeedsUpdate.
        menu.autoenablesItems = false

        // Shown only once a newer version has been found (downloaded copies only).
        let updateAvailable = makeItem("", action: #selector(offerUpdate))
        updateAvailable.isHidden = true
        menu.addItem(updateAvailable)
        let toggle = makeItem("Show Shelf", action: #selector(toggleShelf))
        menu.addItem(toggle)
        let resetPosition = makeItem("Reset Shelf Position", action: #selector(resetShelfPosition))
        menu.addItem(resetPosition)
        let clear = makeItem("Clear Shelf", action: #selector(clearShelf))
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(makeItem("How to Use Stow", action: #selector(showWelcome)))
        let updatesItem = makeItem("Check for Updates…", action: #selector(checkForUpdates))
        // App Store copies are updated by the App Store.
        updatesItem.isHidden = UpdateChecker.isAppStoreCopy
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        toggleShelfItem = toggle
        clearShelfItem = clear
        resetPositionItem = resetPosition
        updateAvailableItem = updateAvailable
        observeStatusItem()
    }

    /// Keeps the menu bar icon up to date: a filled tray while the shelf holds
    /// anything, with the number of items next to it (unless that's turned off in
    /// Settings). Re-arms itself after every change, like ShelfViewController's
    /// observeItems.
    private func observeStatusItem() {
        withObservationTracking {
            updateStatusItem()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStatusItem()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let count = viewModel.items.count
        // SF Symbols are template images, so the icon adapts to light/dark menu bars.
        button.image = NSImage(systemSymbolName: count > 0 ? "tray.full" : "tray", accessibilityDescription: nil)
        button.title = settings.showCountInMenuBar && count > 0 ? "\(count)" : ""
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
        let label = switch count {
        case 0: "Stow"
        case 1: "Stow, 1 item on the shelf"
        default: "Stow, \(count) items on the shelf"
        }
        button.setAccessibilityLabel(label)
    }

    // MARK: - Keyboard shortcut

    /// Registers the shortcut chosen in Settings, and registers it again whenever it
    /// changes. While Settings is recording a new one, none is registered, so pressing
    /// the current shortcut gets recorded instead of toggling the shelf.
    private func observeShortcut() {
        let combo = withObservationTracking {
            settings.isRecordingShortcut ? nil : settings.shortcut
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeShortcut()
            }
        }
        if hotKey?.register(combo) == true {
            settings.shortcutProblem = nil
        } else {
            let name = combo?.display ?? "The shortcut"
            settings.shortcutProblem = "\(name) couldn't be set up. Another app may be using it, so try a different one."
            NSLog("Stow: couldn't register the shortcut \(name).")
        }
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    /// Called just before the menu opens, so its titles always match the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleShelfItem?.title = shelf.isShown ? "Hide Shelf" : "Show Shelf"
        // Clear Shelf keeps pinned items, so there has to be something unpinned.
        clearShelfItem?.isEnabled = viewModel.items.contains { !$0.isPinned }
        if let update = updateChecker.availableUpdate {
            updateAvailableItem?.title = "Download Stow \(update.version)…"
            updateAvailableItem?.isHidden = false
        } else {
            updateAvailableItem?.isHidden = true
        }
        updateChecker.checkIfDue()
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

    @objc private func showWelcome() {
        welcomeWindow.show()
    }

    @objc private func checkForUpdates() {
        Task {
            await updateChecker.check(userInitiated: true)
        }
    }

    @objc private func offerUpdate() {
        if let update = updateChecker.availableUpdate {
            updateChecker.offer(update)
        }
    }
}
