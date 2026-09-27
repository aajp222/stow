import AppKit

/// The shelf's root view and its drop target. It covers the whole shelf, so things
/// can be dropped anywhere on it, including on the empty state.
///
/// It handles two kinds of drag: things arriving from other apps, and the shelf's own
/// items being dragged within it to reorder them ("internal" drags).
final class ShelfDropView: NSView {
    var onDrop: ([IncomingItem]) -> Void = { _ in }
    var onTargetedChange: (Bool) -> Void = { _ in }

    /// Whether a drag started on the shelf itself. Set by ShelfViewController.
    var isInternal: (NSDraggingInfo) -> Bool = { _ in false }
    /// An internal drag moved to this point (window coordinates).
    var onInternalMove: (NSPoint) -> Void = { _ in }
    /// An internal drag was dropped at this point; returns whether it was used.
    var onInternalDrop: (NSPoint) -> Bool = { _ in false }
    /// An internal drag left the shelf or ended.
    var onInternalEnd: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Array(PasteboardContents.acceptedTypes))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Array(PasteboardContents.acceptedTypes))
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isInternal(sender) {
            onInternalMove(sender.draggingLocation)
            return internalOperation(for: sender)
        }
        let operation = operation(for: sender)
        onTargetedChange(!operation.isEmpty)
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isInternal(sender) {
            onInternalMove(sender.draggingLocation)
            return internalOperation(for: sender)
        }
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange(false)
        onInternalEnd()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange(false)
        onInternalEnd()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isInternal(sender) {
            return onInternalDrop(sender.draggingLocation)
        }
        let incoming = PasteboardContents.read(from: sender.draggingPasteboard)
        guard !incoming.isEmpty else { return false }
        onDrop(incoming)
        return true
    }

    /// The operation to show (and report back to the source) for a drag from another app.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard PasteboardContents.offersAcceptedTypes(sender.draggingPasteboard) else { return [] }
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

    /// Reordering is a move within the shelf.
    private func internalOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let allowed = sender.draggingSourceOperationMask
        if allowed.contains(.move) { return .move }
        if allowed.contains(.generic) { return .generic }
        return []
    }
}
