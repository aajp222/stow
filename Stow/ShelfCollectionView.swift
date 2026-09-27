import AppKit
import SwiftUI

/// The shelf's item list. NSCollectionView gives us multi-selection, dragging several
/// items at once, and a callback saying whether the drop succeeded, which SwiftUI's
/// own drag APIs don't provide.
final class ShelfCollectionView: NSCollectionView {
    /// Builds the right-click menu for the current selection. Set by ShelfViewController.
    var contextMenuProvider: () -> NSMenu? = { nil }

    /// Accept the very first click even though the shelf's window isn't key.
    /// Without this, the first click on an inactive window is swallowed, so you'd have
    /// to click an item once before you could drag it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Which operations a drag out of the shelf allows. NSCollectionView is the drag
    /// source (NSDraggingSource) for its items, and AppKit asks this again as the drag
    /// moves and modifier keys change.
    ///
    /// The shelf holds references to the *original* files, so a plain drag into a
    /// Finder folder on the same disk would move the original away. Offer only "copy"
    /// by default. Holding ⌘ offers "move", matching Finder's own ⌘-drag.
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication:
            // No reordering, and no dropping items back onto the shelf.
            return []
        case .outsideApplication:
            return NSEvent.modifierFlags.contains(.command) ? [.move, .generic] : .copy
        @unknown default:
            return .copy
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        // Right-clicking an item that isn't selected selects just that item, like Finder.
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return contextMenuProvider()
    }
}

/// One cell of the collection view, hosting the SwiftUI `ShelfItemView`.
final class ShelfItemCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ShelfItemCell")

    private var item: ShelfItem?
    private var hostingView: NSHostingView<ShelfItemView>?

    override func loadView() {
        view = CellContainerView()
    }

    func configure(with item: ShelfItem) {
        self.item = item
        render()
    }

    override var isSelected: Bool {
        didSet { render() }
    }

    private func render() {
        guard let item else { return }
        let rootView = ShelfItemView(item: item, isSelected: isSelected)
        if let hostingView {
            hostingView.rootView = rootView
            return
        }
        let hostingView = NSHostingView(rootView: rootView)
        // Let the cell decide the size instead of SwiftUI's preferred size.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.hostingView = hostingView
    }
}

/// The cell's root view. It claims every mouse event inside itself, so the SwiftUI
/// view never sees (and never swallows) the clicks and drags NSCollectionView needs.
/// Unhandled mouse events travel up the responder chain to the collection view,
/// which does the selecting and dragging.
private final class CellContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates, the same space as `frame`.
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var ancestor = superview
        while let view = ancestor, !(view is ShelfCollectionView) {
            ancestor = view.superview
        }
        return ancestor?.menu(for: event)
    }
}
