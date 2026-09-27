import AppKit
import UniformTypeIdentifiers

/// The "Stow" entry in every app's Share menu.
///
/// A share extension is a separate little program that macOS runs when you pick it
/// from a Share menu, in its own sandbox. It can't give Stow the files you shared
/// directly, so it copies them (and any text or links) into a folder that Stow and
/// the extension both use, an App Group container, then wakes Stow. Stow picks them
/// up from there and puts them on the shelf (see ShareInbox.swift in the app).
///
/// Each share is assembled in a hidden folder and renamed into place once complete,
/// so Stow never sees half of one.
final class ShareViewController: NSViewController {
    override func loadView() {
        // There's nothing to show: sharing happens straight away.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            let shared = await share()
            if shared {
                wakeStow()
                extensionContext?.completeRequest(returningItems: nil)
            } else {
                extensionContext?.cancelRequest(withError: CocoaError(.fileWriteUnknown))
            }
        }
    }

    /// Copies everything shared into a new inbox folder. Returns false if nothing
    /// could be copied.
    private func share() async -> Bool {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let inbox = SharedInbox.url else { return false }
        let fileManager = FileManager.default
        let incoming = inbox.appending(path: ".incoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        } catch {
            return false
        }

        var entries: [SharedInbox.Entry] = []
        for provider in providers {
            if let entry = await Self.entry(for: provider, copyingInto: incoming) {
                entries.append(entry)
            }
        }
        guard !entries.isEmpty,
              let manifest = try? JSONEncoder().encode(entries),
              (try? manifest.write(to: incoming.appending(path: SharedInbox.manifestName))) != nil else {
            try? fileManager.removeItem(at: incoming)
            return false
        }
        // Renaming it into place is what Stow watches for.
        do {
            try fileManager.moveItem(at: incoming, to: inbox.appending(path: UUID().uuidString, directoryHint: .isDirectory))
            return true
        } catch {
            try? fileManager.removeItem(at: incoming)
            return false
        }
    }

    /// Launches Stow if it isn't running (it notices the new share by itself if it is).
    /// Stow registers the "stow:" URL scheme for this.
    private func wakeStow() {
        guard let url = URL(string: "stow://inbox") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    }

    // MARK: - Reading what was shared

    /// One shared thing: a file (copied into `folder`), a web link or some text.
    private static func entry(for provider: NSItemProvider, copyingInto folder: URL) async -> SharedInbox.Entry? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let url = await loadURL(provider, type: .fileURL), url.isFileURL,
                  let name = copy(url, into: folder) else { return nil }
            return SharedInbox.Entry(kind: .file, value: name)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = await loadURL(provider, type: .url) else { return nil }
            return SharedInbox.Entry(kind: .link, value: url.absoluteString)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            guard let name = await copyFileRepresentation(provider, type: .image, into: folder) else { return nil }
            return SharedInbox.Entry(kind: .file, value: name)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            guard let text = await loadText(provider), !text.isEmpty else { return nil }
            return SharedInbox.Entry(kind: .text, value: text)
        }
        return nil
    }

    /// The completion handlers below run on a background queue, so they're
    /// `@Sendable` and hand back only plain values.
    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { @Sendable item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { @Sendable item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let text = item as? NSAttributedString {
                    continuation.resume(returning: text.string)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// For images shared as data rather than as a file (from a browser, say). The
    /// temporary file is deleted when the handler returns, so it's copied inside it.
    private static func copyFileRepresentation(_ provider: NSItemProvider, type: UTType, into folder: URL) async -> String? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { @Sendable url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                var name = url.lastPathComponent
                if let suggestedName, !suggestedName.isEmpty {
                    name = url.pathExtension.isEmpty ? suggestedName : "\(suggestedName).\(url.pathExtension)"
                }
                continuation.resume(returning: Self.copy(url, into: folder, named: name))
            }
        }
    }

    /// Copies a file into the share's folder, renaming it if the name is taken.
    /// Returns the name it was saved under.
    nonisolated private static func copy(_ url: URL, into folder: URL, named name: String? = nil) -> String? {
        let fileManager = FileManager.default
        let name = name ?? url.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while fileManager.fileExists(atPath: folder.appending(path: candidate).path) {
            candidate = pathExtension.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(pathExtension)"
            number += 1
        }
        do {
            try fileManager.copyItem(at: url, to: folder.appending(path: candidate))
            return candidate
        } catch {
            return nil
        }
    }
}

/// Where shares wait for Stow, and how each one is described. Stow's ShareInbox reads
/// the same format; keep the two in step.
enum SharedInbox {
    /// The App Group Stow and this extension share. Prefixed with the team ID, which
    /// is how macOS apps outside the App Store may use app groups too.
    static let groupID = "2MUHC6TNGW.com.aaryanjigarpanchal.Stow"
    static let manifestName = "items.json"

    struct Entry: Codable {
        enum Kind: String, Codable {
            case file, text, link
        }

        var kind: Kind
        /// A file's name in the share's folder, the text itself, or the link.
        var value: String
    }

    static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }
}
