import Carbon.HIToolbox
import Foundation
import Observation
import ServiceManagement

/// A keyboard shortcut, stored the way Carbon's RegisterEventHotKey wants it.
struct KeyCombo: Equatable, Codable {
    /// A virtual key code, such as kVK_ANSI_S.
    var keyCode: Int
    /// Carbon modifier flags (cmdKey, controlKey, optionKey, shiftKey).
    var modifiers: Int
    /// How the shortcut reads, such as "⌃⌥S".
    var display: String

    static let `default` = KeyCombo(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey, display: "⌃⌥S")
}

/// What brings the shelf in while you drag something.
enum ShelfTrigger: String, CaseIterable {
    /// As soon as anything the shelf can take is picked up.
    case anyDrag
    /// Once the drag reaches the left or right side of the screen.
    case screenEdge
    /// When you shake the pointer while dragging. The shelf appears next to it.
    case shake
}

/// Which side the shelf docks to when it places itself (see ShelfPlacement).
enum DockEdgePreference: String, CaseIterable {
    /// Whichever side of the screen is nearer the pointer when a drag starts.
    case nearest
    case left
    case right
}

/// The user's settings, saved in UserDefaults. The Settings window edits these, and
/// the rest of the app reads them.
///
/// Each setting is a computed property that reads and writes UserDefaults directly,
/// so there's one copy of the value. `access(keyPath:)` and `withMutation(keyPath:)`
/// come from the `@Observable` macro: calling them tells SwiftUI (and
/// `withObservationTracking`) when a setting is read and when it changes, which a
/// stored property would do automatically.
@Observable
final class AppSettings {
    private enum Key {
        static let removeAfterDrag = "RemoveAfterDrag"
        static let visibleItemLimit = "VisibleItemLimit"
        static let dockEdge = "DockEdge"
        /// Replaced by `shelfTrigger`; read once to carry the old choice over.
        static let showOnlyAtScreenEdge = "ShowOnlyAtScreenEdge"
        static let shelfTrigger = "ShelfTrigger"
        static let stackDroppedFiles = "StackDroppedFiles"
        static let showCountInMenuBar = "ShowCountInMenuBar"
        static let shortcut = "Shortcut"
        static let stowScreenshots = "StowScreenshots"
        static let screenshotFolder = "ScreenshotFolderBookmark"
        static let checkForUpdates = "CheckForUpdates"
        static let lastUpdateCheck = "LastUpdateCheck"
        static let hasSeenWelcome = "HasSeenWelcome"
    }

    /// The allowed range for "Items shown before scrolling".
    static let visibleItemRange = 1...12

    @ObservationIgnored private let defaults: UserDefaults

    /// `defaults` is where settings are kept; tests pass a scratch suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.removeAfterDrag: true,
            Key.visibleItemLimit: 4,
            Key.dockEdge: DockEdgePreference.nearest.rawValue,
            Key.showOnlyAtScreenEdge: false,
            Key.stackDroppedFiles: true,
            Key.showCountInMenuBar: true,
            Key.stowScreenshots: false,
            Key.checkForUpdates: true,
            Key.hasSeenWelcome: false,
        ])
        loginItemStatus = SMAppService.mainApp.status
    }

    /// Take items off the shelf once they've been dragged out and dropped somewhere.
    var removeAfterDrag: Bool {
        get {
            access(keyPath: \.removeAfterDrag)
            return defaults.bool(forKey: Key.removeAfterDrag)
        }
        set {
            withMutation(keyPath: \.removeAfterDrag) {
                defaults.set(newValue, forKey: Key.removeAfterDrag)
            }
        }
    }

    /// How many items the shelf grows to fit before the list starts scrolling.
    var visibleItemLimit: Int {
        get {
            access(keyPath: \.visibleItemLimit)
            let stored = defaults.integer(forKey: Key.visibleItemLimit)
            return min(max(stored, Self.visibleItemRange.lowerBound), Self.visibleItemRange.upperBound)
        }
        set {
            withMutation(keyPath: \.visibleItemLimit) {
                defaults.set(newValue, forKey: Key.visibleItemLimit)
            }
        }
    }

    var dockEdge: DockEdgePreference {
        get {
            access(keyPath: \.dockEdge)
            return DockEdgePreference(rawValue: defaults.string(forKey: Key.dockEdge) ?? "") ?? .nearest
        }
        set {
            withMutation(keyPath: \.dockEdge) {
                defaults.set(newValue.rawValue, forKey: Key.dockEdge)
            }
        }
    }

    /// What brings the shelf in during a drag. Versions before this setting had an
    /// on/off "only at the side of the screen" option, which carries over.
    var shelfTrigger: ShelfTrigger {
        get {
            access(keyPath: \.shelfTrigger)
            if let stored = defaults.string(forKey: Key.shelfTrigger), let trigger = ShelfTrigger(rawValue: stored) {
                return trigger
            }
            return defaults.bool(forKey: Key.showOnlyAtScreenEdge) ? .screenEdge : .anyDrag
        }
        set {
            withMutation(keyPath: \.shelfTrigger) {
                defaults.set(newValue.rawValue, forKey: Key.shelfTrigger)
            }
        }
    }

    /// Files dropped together (two or more at once) become one stack.
    var stackDroppedFiles: Bool {
        get {
            access(keyPath: \.stackDroppedFiles)
            return defaults.bool(forKey: Key.stackDroppedFiles)
        }
        set {
            withMutation(keyPath: \.stackDroppedFiles) {
                defaults.set(newValue, forKey: Key.stackDroppedFiles)
            }
        }
    }

    /// Show how many items are on the shelf next to the menu bar icon.
    var showCountInMenuBar: Bool {
        get {
            access(keyPath: \.showCountInMenuBar)
            return defaults.bool(forKey: Key.showCountInMenuBar)
        }
        set {
            withMutation(keyPath: \.showCountInMenuBar) {
                defaults.set(newValue, forKey: Key.showCountInMenuBar)
            }
        }
    }

    // MARK: - Screenshots

    /// Put new screenshots on the shelf as soon as they're saved.
    var stowScreenshots: Bool {
        get {
            access(keyPath: \.stowScreenshots)
            return defaults.bool(forKey: Key.stowScreenshots)
        }
        set {
            withMutation(keyPath: \.stowScreenshots) {
                defaults.set(newValue, forKey: Key.stowScreenshots)
            }
        }
    }

    /// The folder screenshots are saved in, as a security-scoped bookmark: the sandbox
    /// only lets Stow watch a folder you've chosen, and the bookmark keeps that
    /// permission across relaunches. Set by choosing the folder in Settings.
    var screenshotFolderBookmark: Data? {
        get {
            access(keyPath: \.screenshotFolderBookmark)
            return defaults.data(forKey: Key.screenshotFolder)
        }
        set {
            withMutation(keyPath: \.screenshotFolderBookmark) {
                defaults.set(newValue, forKey: Key.screenshotFolder)
            }
        }
    }

    // MARK: - Updates and welcome

    /// Look for a newer version on GitHub once a day (downloaded copies only; the App
    /// Store updates its own copies).
    var checkForUpdates: Bool {
        get {
            access(keyPath: \.checkForUpdates)
            return defaults.bool(forKey: Key.checkForUpdates)
        }
        set {
            withMutation(keyPath: \.checkForUpdates) {
                defaults.set(newValue, forKey: Key.checkForUpdates)
            }
        }
    }

    /// When Stow last looked for an update. Not shown anywhere, so not observed.
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// Whether the welcome card has been shown (it opens by itself only once).
    var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Key.hasSeenWelcome) }
        set { defaults.set(newValue, forKey: Key.hasSeenWelcome) }
    }

    // MARK: - Shortcut

    /// The global shortcut that shows or hides the shelf, or nil for none. Stored as
    /// JSON; never having set one means the default, ⌃⌥S.
    var shortcut: KeyCombo? {
        get {
            access(keyPath: \.shortcut)
            guard let data = defaults.data(forKey: Key.shortcut) else { return KeyCombo.default }
            // A stored `null` means you cleared the shortcut, which is different from
            // a value that won't decode (then fall back to the default).
            do {
                return try JSONDecoder().decode(KeyCombo?.self, from: data)
            } catch {
                return KeyCombo.default
            }
        }
        set {
            withMutation(keyPath: \.shortcut) {
                defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.shortcut)
            }
        }
    }

    /// True while the Settings window is recording a new shortcut. The current one is
    /// switched off meanwhile, so pressing it gets recorded instead of toggling the
    /// shelf. Not saved.
    var isRecordingShortcut = false

    /// Why the shortcut couldn't be registered, if it couldn't. Not saved.
    var shortcutProblem: String?

    // MARK: - Open at login

    /// Whether Stow is registered as a login item. The system keeps this, not
    /// UserDefaults, so we mirror its status here and refresh it when the Settings
    /// window opens (you can also change it in System Settings).
    private(set) var loginItemStatus: SMAppService.Status
    /// Why the last attempt to change "Open at login" failed, if it did.
    private(set) var loginItemError: String?

    var launchAtLogin: Bool {
        get { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }
        set {
            // SMAppService.mainApp is Stow itself. Registering adds it to System
            // Settings > General > Login Items.
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
            }
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }
}
