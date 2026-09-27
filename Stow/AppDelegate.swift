import AppKit

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

/// Owns the menu bar icon and its menu.
///
/// There is no Dock icon and no main window: `INFOPLIST_KEY_LSUIElement = YES` in the
/// target's build settings writes `LSUIElement` into the generated Info.plist, which
/// makes macOS treat Stow as an "agent" app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // SF Symbols are template images, so the icon adapts to light/dark menu bars.
        item.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Stow")

        let menu = NSMenu()
        menu.addItem(makeItem("Show Shelf", action: #selector(toggleShelf)))
        menu.addItem(makeItem("Clear Shelf", action: #selector(clearShelf)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func toggleShelf() {
        // Phase 2 adds the shelf.
    }

    @objc private func clearShelf() {
        // Phase 2 adds the shelf.
    }
}
