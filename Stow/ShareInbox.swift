import Foundation

/// Picks up what the Share menu's "Stow" entry (the StowShare extension) leaves for
/// Stow, and hands it over as if it had been dropped on the shelf.
///
/// The extension runs in its own sandbox, so it copies what you share into a folder
/// in the App Group container the two share: `Inbox/<one folder per share>/`, with
/// an `items.json` saying what's there. Stow watches that folder, moves the files
/// into its own storage (so they're Stow copies, cleaned up once removed), and
/// deletes the share's folder.
final class ShareInbox {
    /// Must match the extension's SharedInbox (StowShare/ShareViewController.swift)
    /// and both targets' entitlements.
    static let groupID = "2MUHC6TNGW.com.aaryanjigarpanchal.Stow"
    private static let manifestName = "items.json"

    private struct Entry: Codable {
        enum Kind: String, Codable {
            case file, text, link
        }

        var kind: Kind
        var value: String
    }

    /// Called with the items from each share, in order.
    var onItems: ([IncomingItem]) -> Void = { _ in }
    private var watcher: FolderWatcher?

    private static var inboxURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Takes anything shared while Stow wasn't running, then watches for more.
    func start() {
        guard watcher == nil, let inbox = Self.inboxURL else { return }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // The extension renames each finished share into the inbox, which changes
        // the inbox's list of entries and so wakes the watcher.
        watcher = FolderWatcher(folder: inbox) { [weak self] in self?.importPending() }
        importPending()
    }

    /// Imports every finished share. Safe to call any time; each share is imported
    /// once, then deleted.
    func importPending() {
        guard let inbox = Self.inboxURL else { return }
        let fileManager = FileManager.default
        let shares = (try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey])) ?? []
        // Hidden folders are shares the extension is still writing.
        let finished = shares
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { Self.creationDate($0) < Self.creationDate($1) }
        for share in finished {
            let incoming = items(in: share)
            try? fileManager.removeItem(at: share)
            if !incoming.isEmpty {
                onItems(incoming)
            }
        }
    }

    private func items(in share: URL) -> [IncomingItem] {
        guard let data = try? Data(contentsOf: share.appending(path: Self.manifestName)),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        let store = PromisedFileStore()
        var items: [IncomingItem] = []
        for entry in entries {
            switch entry.kind {
            case .file:
                // Move the copy into Stow's own storage, where it's a Stow copy.
                let source = share.appending(path: entry.value)
                guard let folder = try? store.makeDropFolder() else { continue }
                let destination = folder.appending(path: entry.value)
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                    items.append(.file(destination))
                } catch {
                    NSLog("Stow: couldn't take in a shared file: \(error.localizedDescription)")
                }
            case .text:
                items.append(.text(entry.value))
            case .link:
                if let url = URL(string: entry.value) {
                    items.append(.link(url, title: nil))
                }
            }
        }
        return items
    }

    private static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }
}
