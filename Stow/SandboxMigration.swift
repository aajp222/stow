import Foundation

/// Stow used to run in the App Sandbox, which kept its settings and files inside
/// `~/Library/Containers/com.aaryanjigarpanchal.Stow/Data/`. Now that it doesn't, it
/// reads them from the usual places in your home folder. This moves them there once,
/// the first time the unsandboxed Stow starts, so the shelf and your settings carry
/// over.
enum SandboxMigration {
    private static let doneKey = "MigratedOutOfSandbox"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        let fileManager = FileManager.default
        let library = ScreenshotWatcher.realHomeFolder.appending(path: "Library", directoryHint: .isDirectory)
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let container = library.appending(path: "Containers/\(bundleID)/Data/Library", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: container.path) else { return }

        // Settings: the sandboxed copy is the newer one.
        let oldPreferences = container.appending(path: "Preferences/\(bundleID).plist")
        if let saved = NSDictionary(contentsOf: oldPreferences) as? [String: Any] {
            for (key, value) in saved {
                defaults.set(value, forKey: key)
            }
        }

        // The shelf and Stow's own copies. A Stow folder already in the real
        // Application Support is from before the sandbox, so it goes to the Trash.
        let oldFolder = container.appending(path: "Application Support/Stow", directoryHint: .isDirectory)
        let newFolder = URL.applicationSupportDirectory.appending(path: "Stow", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: oldFolder.path) else { return }
        do {
            if fileManager.fileExists(atPath: newFolder.path) {
                try fileManager.trashItem(at: newFolder, resultingItemURL: nil)
            }
            try fileManager.createDirectory(at: newFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A move on the same disk keeps each file's identity, so the shelf's
            // bookmarks find Stow's copies in their new place.
            try fileManager.moveItem(at: oldFolder, to: newFolder)
        } catch {
            NSLog("Stow: couldn't move its files out of the sandbox container: \(error.localizedDescription)")
        }
    }
}
