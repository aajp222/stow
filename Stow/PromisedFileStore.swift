import Foundation

/// Owns the folder where file promises are written:
/// `~/Library/Application Support/Stow/Promised/<one folder per drop>/<file>`.
///
/// A promised file is often the *only* copy (dragging a screenshot thumbnail doesn't
/// save it anywhere else), so Stow always moves these files to the Trash instead of
/// deleting them outright.
struct PromisedFileStore {
    let rootURL = URL.applicationSupportDirectory
        .appending(path: "Stow/Promised", directoryHint: .isDirectory)

    /// A fresh, uniquely named folder for one drop, so two promised files with the
    /// same name (two "Screenshot.png"s, say) never collide.
    func makeDropFolder() throws -> URL {
        let folder = rootURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Whether `url` is inside the Promised folder. Stow never trashes anything else.
    func owns(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/")
    }

    /// Moves promised copies to the Trash and removes their drop folders once empty.
    func trash(_ urls: [URL]) {
        let fileManager = FileManager.default
        for url in urls where owns(url) {
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    NSLog("Stow: couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
                }
            }
            removeIfEmpty(url.deletingLastPathComponent())
        }
    }

    /// Trashes everything in the Promised folder except `keep`. Run at launch to clear
    /// out files left behind by items that are no longer on the shelf.
    func trashAll(except keep: Set<URL> = []) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return
        }
        for folder in folders {
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            trash(files.filter { !keep.contains($0.standardizedFileURL) })
            removeIfEmpty(folder)
        }
    }

    private func removeIfEmpty(_ folder: URL) {
        guard owns(folder) else { return }
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
            try? fileManager.removeItem(at: folder)
        }
    }
}
