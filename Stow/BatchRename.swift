import Darwin
import Foundation

/// Renames the original files, rather than making shelf copies. Moving every file
/// aside first lets a batch reuse its own names without losing either file.
enum BatchRename {
    struct Pattern: Sendable {
        let baseName: String
        let startNumber: Int
        let keepExtension: Bool

        nonisolated init(baseName: String, startNumber: Int = 1, keepExtension: Bool = true) {
            self.baseName = baseName
            self.startNumber = startNumber
            self.keepExtension = keepExtension
        }
    }

    /// The preview and the actual rename use the same numbering. Widen the whole
    /// batch together when its count or its last number needs more than two digits.
    /// An impossible number range has no preview; `rename` explains why it is invalid.
    nonisolated static func newNames(for urls: [URL], pattern: Pattern) -> [String] {
        guard pattern.startNumber >= 0 else { return [] }
        let (last, overflow) = pattern.startNumber.addingReportingOverflow(max(0, urls.count - 1))
        guard !overflow else { return [] }
        let width = max(2, String(urls.count).count, String(last).count)
        return urls.enumerated().map { index, url in
            let number = String(pattern.startNumber + index)
            let stem = pattern.baseName + " " + String(repeating: "0", count: width - number.count) + number
            // A folder's suffix isn't a file extension. Folders are refused by rename.
            let suffix = pattern.keepExtension ? url.pathExtension : ""
            return suffix.isEmpty ? stem : stem + "." + suffix
        }
    }

    /// Refuses outside conflicts before touching anything. Each move also refuses
    /// replacement atomically, in case another app creates a file after that check.
    nonisolated static func rename(_ urls: [URL], pattern: Pattern) throws -> [URL] {
        try rename(urls, pattern: pattern, move: moveWithoutReplacing)
    }

    /// Keeping the move operation injectable lets tests cause a failure halfway
    /// through a real transaction, without relying on disk space or permissions.
    nonisolated static func rename(
        _ urls: [URL], pattern: Pattern, move: (URL, URL) throws -> Void
    ) throws -> [URL] {
        try validate(pattern.baseName)
        let names = newNames(for: urls, pattern: pattern)
        guard pattern.startNumber >= 0, names.count == urls.count else {
            throw BatchRenameError.invalidNumber
        }
        // Resolve the parent only: renaming a symbolic link should move the link,
        // never the file it points to. This also catches duplicate folder aliases.
        let sources = try urls.map { url in
            guard url.isFileURL else { throw BatchRenameError.notAFile(url.lastPathComponent) }
            let source = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appending(path: url.lastPathComponent).standardizedFileURL
            guard let attributes = try attributes(at: source), attributes[.type] as? FileAttributeType != .typeDirectory else {
                throw BatchRenameError.notAFile(url.lastPathComponent)
            }
            return source
        }
        let destinations = zip(sources, names).map { $0.deletingLastPathComponent().appending(path: $1) }
        let sourceKeys = try sources.map { try pathKey($0) }
        guard Set(sourceKeys).count == sources.count else { throw BatchRenameError.duplicateFile }
        let destinationKeys = try destinations.map { try pathKey($0) }
        guard Set(destinationKeys).count == destinations.count else { throw BatchRenameError.duplicateName }
        for (index, destination) in destinations.enumerated() {
            if try attributes(at: destination) != nil, !sourceKeys.contains(destinationKeys[index]) {
                throw BatchRenameError.nameTaken(destination.lastPathComponent)
            }
        }
        let temporary = sources.map {
            $0.deletingLastPathComponent().appending(path: ".Stow Rename \(UUID().uuidString)")
        }
        var locations = Array(repeating: Location.original, count: sources.count)
        do {
            for index in sources.indices {
                try move(sources[index], temporary[index])
                locations[index] = .temporary
            }
            for index in sources.indices {
                try move(temporary[index], destinations[index])
                locations[index] = .destination
            }
        } catch {
            let reason = error.localizedDescription
            // First undo the final moves, so a cycle can't block its own rollback.
            // Never delete a temporary file: it may be the only copy of someone's data.
            for index in sources.indices.reversed() where locations[index] == .destination {
                do {
                    try move(destinations[index], temporary[index])
                    locations[index] = .temporary
                } catch { /* Keep trying to restore the other files. */ }
            }
            for index in sources.indices.reversed() where locations[index] == .temporary {
                do {
                    try move(temporary[index], sources[index])
                    locations[index] = .original
                } catch { /* Report the remaining files below, with their actual paths. */ }
            }
            let remaining = sources.indices.compactMap { index -> URL? in
                switch locations[index] {
                case .original: nil
                case .temporary: temporary[index]
                case .destination: destinations[index]
                }
            }
            if !remaining.isEmpty { throw BatchRenameError.rollbackFailed(remaining) }
            throw BatchRenameError.renameFailed(reason)
        }
        // Return the spelling requested by the caller, including case-only changes.
        return destinations
    }

    nonisolated private enum Location: Sendable { case original, temporary, destination }

    nonisolated private static func validate(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BatchRenameError.emptyName
        }
        guard !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw BatchRenameError.invalidName
        }
    }

    nonisolated private static func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            // Unlike fileExists, this notices dangling symbolic links too.
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
    }

    /// macOS volumes can be case-sensitive or case-insensitive. Compare names the
    /// way that folder does, including canonically equivalent Unicode spellings.
    nonisolated private static func pathKey(_ url: URL) throws -> String {
        let parent = url.deletingLastPathComponent()
        let sensitive = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
        return parent.path.precomposedStringWithCanonicalMapping + "/" + (sensitive ? name : name.lowercased())
    }

    nonisolated private static func moveWithoutReplacing(_ source: URL, _ destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                renameatx_np(AT_FDCWD, sourcePath!, AT_FDCWD, destinationPath!, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

enum BatchRenameError: LocalizedError {
    case emptyName
    case invalidName
    case invalidNumber
    case notAFile(String)
    case duplicateFile
    case duplicateName
    case nameTaken(String)
    case renameFailed(String)
    case rollbackFailed([URL])

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for the files."
        case .invalidName: "File names can't contain /, : or a null character."
        case .invalidNumber: "Choose a starting number of zero or more that leaves room for every file."
        case .notAFile(let name): "“\(name)” isn't an available file. Choose files, rather than folders."
        case .duplicateFile: "The same file appears more than once. Choose each file only once."
        case .duplicateName: "Two files would have the same name. Choose a different pattern."
        case .nameTaken(let name): "“\(name)” already exists outside this batch. Choose a different name or starting number."
        case .renameFailed(let reason): "The files couldn't be renamed. Their original names have been restored. \(reason)"
        case .rollbackFailed(let urls):
            "The rename stopped and some original names couldn't be restored. Your files are still at these locations:\n" + urls.map(\.path).joined(separator: "\n")
        }
    }
}
