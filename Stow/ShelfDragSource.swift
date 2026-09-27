import AppKit

/// The drag source for items dragged off the shelf.
///
/// NSCollectionView can run drags for its rows by itself, but only one pasteboard item
/// per row. A stack row stands for several files, so the shelf starts its own drag
/// session instead (ShelfViewController.beginDrag), with one dragging item per file,
/// and this object answers AppKit's questions about that session.
final class ShelfDragSource: NSObject, NSDraggingSource {
    /// The items being dragged.
    private(set) var itemIDs: [ShelfItem.ID] = []
    /// Members dragged out on their own rather than with their whole stack. If
    /// they're dropped back on the shelf, they leave the stack.
    private(set) var detachedIDs: Set<ShelfItem.ID> = []
    /// Set by the shelf when the items were dropped back onto it (a reorder).
    var droppedOnShelf = false

    /// Called once the drag is over, with where it ended (screen coordinates) and what
    /// the drop target did (empty if nothing accepted the items).
    var onEnded: (_ itemIDs: [ShelfItem.ID], _ operation: NSDragOperation, _ endPoint: NSPoint, _ droppedOnShelf: Bool) -> Void = { _, _, _, _ in }
    /// The area around the shelf (screen coordinates) where items let go slide back
    /// instead of being flicked off.
    var shelfFrame: () -> NSRect = { .zero }

    func begin(itemIDs: [ShelfItem.ID], detachedIDs: Set<ShelfItem.ID>) {
        self.itemIDs = itemIDs
        self.detachedIDs = detachedIDs
        droppedOnShelf = false
    }

    /// Which operations the drag allows. AppKit asks again as the drag moves and as
    /// modifier keys change.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication:
            // Back onto the shelf, to reorder.
            return [.move, .generic]
        case .outsideApplication:
            // The shelf holds references to the *original* files, so a plain drag into
            // a Finder folder on the same disk would move the original away. Offer
            // only "copy" by default. Holding ⌘ offers "move", like Finder's ⌘-drag.
            return NSEvent.modifierFlags.contains(.command) ? [.move, .generic] : .copy
        @unknown default:
            return .copy
        }
    }

    /// Items let go near the shelf where nothing takes them slide back to it. Farther
    /// away they're being flicked off, and vanish in a puff of smoke instead (see
    /// ShelfViewController.dragEnded), so they shouldn't slide back first.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        session.animatesToStartingPositionsOnCancelOrFail = shelfFrame().contains(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let ids = itemIDs
        let dropped = droppedOnShelf
        itemIDs = []
        detachedIDs = []
        droppedOnShelf = false
        onEnded(ids, operation, screenPoint, dropped)
    }
}
