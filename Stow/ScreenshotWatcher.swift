import Foundation

/// Calls `onChange` whenever files are added to, removed from or renamed in a folder.
///
/// It's a dispatch source on the folder itself: the kernel reports a "write" to a
/// directory whenever its list of entries changes. That's cheaper than FSEvents for a
/// single folder, and needs nothing beyond permission to read the folder.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(folder: URL, onChange: @escaping @MainActor () -> Void) {
        // O_EVTONLY opens the folder for notifications only, so it doesn't stop the
        // disk it's on from being ejected.
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler {
            // The source delivers on the main queue (see above).
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    func stop() {
        source.cancel()
    }
}

/// Puts new screenshots on the shelf: watches the folder you chose in Settings and
/// reports screenshots and screen recordings as they're saved to it.
final class ScreenshotWatcher {
    var onScreenshots: ([URL]) -> Void = { _ in }

    private var folder: URL?
    private var watcher: FolderWatcher?
    /// The folder's contents at the last look, so only new files are reported.
    private var known: Set<String> = []
    private var isScanScheduled = false
    /// Folders whose security-scoped access has been started. Access is never given
    /// up during a session: screenshots already on the shelf still need it.
    private var accessedFolders: Set<URL> = []

    /// Starts watching the folder `bookmark` points to, or stops watching when it's nil.
    func watch(bookmark: Data?) {
        watcher?.stop()
        watcher = nil
        folder = nil
        known = []
        guard let bookmark, let folder = Self.resolve(bookmark) else { return }
        // A sandboxed app can only look inside a folder you chose, and only after
        // starting access through the bookmark that remembers your choice.
        if !accessedFolders.contains(folder) {
            guard folder.startAccessingSecurityScopedResource() else { return }
            accessedFolders.insert(folder)
        }
        self.folder = folder
        known = Self.contents(of: folder)
        watcher = FolderWatcher(folder: folder) { [weak self] in self?.scheduleScan() }
    }

    /// The screenshot tool writes a hidden temporary file and then renames it, so wait
    /// a moment for the folder to settle before looking.
    private func scheduleScan() {
        guard !isScanScheduled else { return }
        isScanScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.scan()
        }
    }

    private func scan() {
        isScanScheduled = false
        guard let folder else { return }
        let names = Self.contents(of: folder)
        let added = names.subtracting(known).sorted().map { folder.appending(path: $0) }
        known = names
        let screenshots = added.filter(Self.isScreenshot)
        if !screenshots.isEmpty {
            onScreenshots(screenshots)
        }
        // A file that isn't tagged yet may still be on its way; look once more.
        let untagged = added.filter { !Self.isScreenshot($0) }
        if !untagged.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                let late = untagged.filter(Self.isScreenshot)
                if !late.isEmpty {
                    self?.onScreenshots(late)
                }
            }
        }
    }

    /// Names of the visible files in the folder.
    private static func contents(of folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    /// macOS tags screenshots and screen recordings with an extended attribute (the
    /// one behind Spotlight's kMDItemIsScreenCapture), whatever language their name
    /// is in, so that's what's checked rather than the name.
    nonisolated static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    // MARK: - Remembering the folder

    /// A security-scoped bookmark for a folder you just chose in an Open panel, which
    /// keeps Stow's permission to watch it after a relaunch.
    static func bookmark(for folder: URL) -> Data? {
        try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// Your real home folder. Inside the sandbox, NSHomeDirectory() is Stow's
    /// container, but an Open panel can still start in the real one.
    static var realHomeFolder: URL {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return URL(filePath: String(cString: home), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
