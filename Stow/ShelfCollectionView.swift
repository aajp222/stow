import AppKit
import SwiftUI

/// The shelf's item list. NSCollectionView gives us multi-selection, dragging several
/// items at once, and a callback saying whether the drop succeeded, which SwiftUI's
/// own drag APIs don't provide.
final class ShelfCollectionView: NSCollectionView {
    /// Builds the right-click menu: for the selected items when `onItem` is true,
    /// otherwise for the shelf itself. Set by ShelfViewController.
    var contextMenuProvider: (_ onItem: Bool) -> NSMenu? = { _ in nil }
    /// The selected items' files, offered to the Services menu. Set by ShelfViewController.
    var selectedFileURLs: () -> [URL] = { [] }
    /// The user dragged the shelf by an empty part of the list.
    var onWindowMoved: () -> Void = {}

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

    /// A press on an item selects and drags it as usual. A press on empty space
    /// clears the selection and, if the mouse then moves, drags the whole shelf.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard indexPathForItem(at: point) == nil, let window else {
            super.mouseDown(with: event)
            return
        }
        deselectAll(nil)
        if window.followMouseDrag() {
            onWindowMoved()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else {
            deselectAll(nil)
            return contextMenuProvider(false)
        }
        // Right-clicking an item that isn't selected selects just that item, like Finder.
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return contextMenuProvider(true)
    }

    // MARK: - Services

    /// AppKit asks this when it builds a right-click menu: "can you send data of this
    /// type to a service?" Answering yes for file URLs while items are selected makes
    /// macOS add the Services submenu, listing the services that work on files.
    /// (AppDelegate registers `.fileURL` as a type Stow can send.)
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == .fileURL, returnType == nil, !selectedFileURLs().isEmpty {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

extension ShelfCollectionView: NSServicesMenuRequestor {
    /// When you pick a service, AppKit calls this to get the selected files.
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let urls = selectedFileURLs()
        guard !urls.isEmpty, types.contains(.fileURL) else { return false }
        pboard.clearContents()
        return pboard.writeObjects(urls as [NSURL])
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

    /// The picture that follows the pointer while this item is dragged. By default
    /// AppKit snapshots the cell's view, but SwiftUI content often comes out blank in
    /// those snapshots, so build it from the thumbnail instead.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let item else { return super.draggingImageComponents }
        let thumbnails = ThumbnailProvider.shared
        let image = thumbnails.cachedThumbnail(for: item) ?? thumbnails.icon(for: item)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = thumbnailFrame(fitting: image.size)
        return [component]
    }

    /// Where ShelfItemView draws the 64×64 thumbnail (6 pt from the top, centred),
    /// narrowed to the image's aspect ratio. Frames are in the cell view's coordinates,
    /// which start at the bottom left.
    private func thumbnailFrame(fitting imageSize: NSSize) -> NSRect {
        let side: CGFloat = 64
        let box = NSRect(x: (view.bounds.width - side) / 2, y: view.bounds.height - 6 - side, width: side, height: side)
        guard imageSize.width > 0, imageSize.height > 0 else { return box }
        let scale = min(side / imageSize.width, side / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
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
