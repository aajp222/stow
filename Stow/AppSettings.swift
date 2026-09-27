import Foundation
import Observation
import ServiceManagement

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
        static let showOnlyAtScreenEdge = "ShowOnlyAtScreenEdge"
    }

    /// The allowed range for "Items shown before scrolling".
    static let visibleItemRange = 1...12

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Key.removeAfterDrag: true,
            Key.visibleItemLimit: 4,
            Key.dockEdge: DockEdgePreference.nearest.rawValue,
            Key.showOnlyAtScreenEdge: false,
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

    /// Only bring the shelf in once a drag reaches the left or right side of the
    /// screen, instead of as soon as anything is picked up.
    var showOnlyAtScreenEdge: Bool {
        get {
            access(keyPath: \.showOnlyAtScreenEdge)
            return defaults.bool(forKey: Key.showOnlyAtScreenEdge)
        }
        set {
            withMutation(keyPath: \.showOnlyAtScreenEdge) {
                defaults.set(newValue, forKey: Key.showOnlyAtScreenEdge)
            }
        }
    }

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
