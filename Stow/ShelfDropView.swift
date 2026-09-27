import AppKit

/// The shelf's root view and its drop target. It covers the whole shelf, so files can
/// be dropped anywhere on it, including on the empty state.
final class ShelfDropView: NSView {
    /// The list of file paths that older apps put on the pasteboard instead of
    /// file URLs. Some apps still do.
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// Every pasteboard type that can carry files: file URLs (modern and legacy),
    /// plus all the types a file promise can arrive as. A plain `public.url` can hold
    /// a file URL too, but it's often a web link, so `carriesFiles` checks those.
    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, legacyFilenamesType, .URL]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// What to turn each dragged item into, in order of preference. A promise wins
    /// when an item offers both: the URL alongside a promise can point at a temporary
    /// file that disappears once the drag ends.
    private static let readableClasses: [AnyClass] = [NSFilePromiseReceiver.self, NSURL.self]
    /// Only accept `file://` URLs, not web links (those come in Phase 4).
    private static let readingOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// Whether a drag carries anything the shelf can take: files, folders or file
    /// promises. DragMonitor uses this too, so the shelf only pops up for drags it
    /// can actually accept.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        if types.contains(legacyFilenamesType) { return true }
        // Cheap check first; only then ask the pasteboard to look inside the data
        // (to tell a file:// URL from a web link).
        guard !Set(types).isDisjoint(with: acceptedTypes) else { return false }
        return pasteboard.canReadObject(forClasses: readableClasses, options: readingOptions)
    }

    var shouldAccept: (NSDraggingInfo) -> Bool = { _ in true }
    var onDrop: (_ fileURLs: [URL], _ promises: [NSFilePromiseReceiver]) -> Void = { _, _ in }
    var onTargetedChange: (Bool) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = operation(for: sender)
        onTargetedChange(!operation.isEmpty)
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let objects = sender.draggingPasteboard.readObjects(forClasses: Self.readableClasses, options: Self.readingOptions) ?? []
        var fileURLs: [URL] = []
        var promises: [NSFilePromiseReceiver] = []
        for object in objects {
            if let promise = object as? NSFilePromiseReceiver {
                promises.append(promise)
            } else if let url = object as? URL {
                fileURLs.append(url)
            }
        }
        if fileURLs.isEmpty, promises.isEmpty,
           let paths = sender.draggingPasteboard.propertyList(forType: Self.legacyFilenamesType) as? [String] {
            fileURLs = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !fileURLs.isEmpty || !promises.isEmpty else { return false }
        onDrop(fileURLs, promises)
        return true
    }

    /// The operation to show (and report back to the source) for a drag over the shelf.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard shouldAccept(sender), Self.carriesFiles(sender.draggingPasteboard) else { return [] }
        // The shelf keeps a reference (or, for a promise, receives its own copy), so the
        // source always keeps its file: from the source's side this is a copy. Never
        // answer "move", which could make the source delete the original. The fallbacks
        // cover drags that modifier keys restrict (⌘ allows only generic, ⌃ only link).
        let allowed = sender.draggingSourceOperationMask
        for candidate: NSDragOperation in [.copy, .generic, .link] where allowed.contains(candidate) {
            return candidate
        }
        return []
    }
}
