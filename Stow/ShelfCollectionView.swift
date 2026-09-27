import AppKit
import Carbon.HIToolbox
import Quartz
import SwiftUI

/// The shelf's list. NSCollectionView lays out and recycles the rows. Clicking,
/// selecting and starting drags are handled here, and the rest is reported to
/// ShelfViewController through the closures below.
final class ShelfCollectionView: NSCollectionView {
    /// Builds the right-click menu: for the selected items when `onItem` is true,
    /// otherwise for the shelf itself.
    var contextMenuProvider: (_ onItem: Bool) -> NSMenu? = { _ in nil }
    /// The files the selection stands for, for Quick Look and the Services menu.
    var selectedFileURLs: () -> [URL] = { [] }
    /// The shelf was dragged by an empty part of the list.
    var onWindowMoved: () -> Void = {}
    /// The mouse went down on a selected row and moved: start dragging the selection.
    var onBeginDrag: (NSEvent) -> Void = { _ in }
    /// A row was clicked without dragging (a stack row fans open or closed).
    var onClickRow: (IndexPath) -> Void = { _ in }
    var onDoubleClickRow: (IndexPath) -> Void = { _ in }
    /// The ✕ in a row's corner was clicked.
    var onRemoveRow: (IndexPath) -> Void = { _ in }
    /// Keys: Return, Delete, Esc, ⌘C, typing (to filter), → and ← (open and close stacks).
    var onOpen: () -> Void = {}
    var onDeleteKey: () -> Void = {}
    var onEscape: () -> Void = {}
    var onCopy: () -> Void = {}
    var onType: (String) -> Void = { _ in }
    var onExpand: (_ open: Bool) -> Void = { _ in }

    /// Where a Shift-click range starts.
    private var selectionAnchor: IndexPath?
    /// The app that was active before Quick Look opened, to hand activation back to.
    private var appBeforeQuickLook: NSRunningApplication?

    /// Accept the very first click even though the shelf's window isn't key.
    /// Without this, the first click on an inactive window is swallowed, so you'd have
    /// to click an item once before you could drag it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // MARK: - Mouse

    /// Selection works like Finder: click selects one row, ⌘-click adds or removes a
    /// row, and Shift-click selects a range. Pressing on a selected row and moving the
    /// mouse drags the whole selection. Pressing on empty space drags the shelf itself.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else {
            deselectAll(nil)
            if window.followMouseDrag() {
                onWindowMoved()
            }
            return
        }

        // Clicking an item makes the shelf the key window, so the keyboard shortcuts
        // below reach it. The panel is non-activating, so this doesn't make Stow the
        // active app: the app you're in keeps its menu bar. Until you click an item,
        // the shelf never takes the keyboard.
        window.makeKey()
        window.makeFirstResponder(self)

        // The ✕ only counts while it's showing: if the shelf appeared under a pointer
        // that hasn't moved since, the corner is just part of the item.
        if (item(at: indexPath) as? ShelfItemCell)?.showsRemoveButton == true,
           let rowFrame = layoutAttributesForItem(at: indexPath)?.frame,
           ShelfLayout.removeButtonRect(inRow: rowFrame).contains(point) {
            onRemoveRow(indexPath)
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .shift])
        let wasSelected = selectionIndexPaths.contains(indexPath)
        if modifiers.contains(.shift), let anchor = selectionAnchor ?? selectionIndexPaths.min() {
            let range = min(anchor.item, indexPath.item)...max(anchor.item, indexPath.item)
            selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: 0) })
        } else if !wasSelected {
            if modifiers.contains(.command) {
                selectionIndexPaths.insert(indexPath)
            } else {
                selectionIndexPaths = [indexPath]
            }
            selectionAnchor = indexPath
        }
        reloadQuickLook()

        if event.clickCount >= 2, modifiers.isEmpty {
            onDoubleClickRow(indexPath)
            return
        }

        // Wait to see whether the mouse moves (a drag) or comes back up (a click).
        if let dragEvent = window.waitForDrag(after: event) {
            onBeginDrag(dragEvent)
        } else if modifiers == .command {
            // ⌘-clicking a selected row deselects it (only once it's clear it wasn't
            // the start of a drag).
            if wasSelected {
                selectionIndexPaths.remove(indexPath)
            }
        } else if modifiers.isEmpty {
            // Clicking one row of a multiple selection selects just that row, like Finder.
            selectionIndexPaths = [indexPath]
            selectionAnchor = indexPath
            onClickRow(indexPath)
        }
        reloadQuickLook()
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
            selectionAnchor = indexPath
        }
        return contextMenuProvider(true)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let extending = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_Space:
            toggleQuickLook()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            onOpen()
        case kVK_Delete, kVK_ForwardDelete:
            onDeleteKey()
        case kVK_Escape:
            onEscape()
        case kVK_UpArrow:
            moveSelection(by: -1, extending: extending)
        case kVK_DownArrow:
            moveSelection(by: 1, extending: extending)
        case kVK_RightArrow:
            onExpand(true)
        case kVK_LeftArrow:
            onExpand(false)
        default:
            // Typing letters filters the shelf by name.
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if modifiers.isEmpty, event.specialKey == nil, let characters = event.characters, !characters.isEmpty {
                onType(characters)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// ⌘C and ⌘A. The shelf has no menu bar of its own, so these arrive here as key
    /// equivalents rather than through Edit menu items.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard window?.firstResponder === self, modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            onCopy()
            return true
        case "a":
            selectionIndexPaths = Set((0..<numberOfItems(inSection: 0)).map { IndexPath(item: $0, section: 0) })
            reloadQuickLook()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// ↑ and ↓ move the selection (with Shift, they extend it).
    private func moveSelection(by step: Int, extending: Bool) {
        let count = numberOfItems(inSection: 0)
        guard count > 0 else { return }
        let current = step > 0 ? selectionIndexPaths.max()?.item : selectionIndexPaths.min()?.item
        let next = current.map { min(max($0 + step, 0), count - 1) } ?? (step > 0 ? 0 : count - 1)
        let indexPath = IndexPath(item: next, section: 0)
        if extending {
            selectionIndexPaths.insert(indexPath)
        } else {
            selectionIndexPaths = [indexPath]
            selectionAnchor = indexPath
        }
        scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        reloadQuickLook()
    }

    // MARK: - Quick Look

    /// Space opens Quick Look on the selected files, like in Finder.
    ///
    /// QLPreviewPanel is a shared system window. When it opens, it looks for a
    /// "controller" by walking the responder chain from the key window's first
    /// responder, which is this view (see mouseDown). The three *PreviewPanelControl
    /// methods below are how this view volunteers, and the data source methods tell it
    /// what to show.
    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !selectedFileURLs().isEmpty else {
            NSSound.beep()
            return
        }
        // Quick Look's window only comes to the front for the active app, so activate
        // Stow while it's open and give activation back when it closes.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            appBeforeQuickLook = frontmost
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Keeps an open Quick Look window showing the current selection.
    private func reloadQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        _ = appBeforeQuickLook?.activate(from: .current, options: [])
        appBeforeQuickLook = nil
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

extension ShelfCollectionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedFileURLs().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedFileURLs()
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
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

/// One row of the list, hosting the SwiftUI `ShelfItemView`.
final class ShelfItemCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ShelfItemCell")

    /// VoiceOver's "press" (open the item, or open and close a stack) and "Remove"
    /// action. Set by ShelfViewController.
    var onPress: () -> Void = {}
    var onRemove: () -> Void = {}

    private var row: ShelfRow?
    private var isExpanded = false
    /// The ✕ shows while the pointer is over the row.
    var showsRemoveButton: Bool { isHovered }
    private var isHovered = false {
        didSet {
            if isHovered != oldValue {
                render()
            }
        }
    }
    private var hostingView: NSHostingView<ShelfItemView>?

    override func loadView() {
        let container = CellContainerView()
        container.onHoverChange = { [weak self] hovering in self?.isHovered = hovering }
        container.onPress = { [weak self] in
            self?.onPress()
            return self != nil
        }
        view = container
    }

    func configure(with row: ShelfRow, isExpanded: Bool) {
        self.row = row
        self.isExpanded = isExpanded
        render()
        updateAccessibility()
    }

    override var isSelected: Bool {
        didSet {
            render()
            view.setAccessibilitySelected(isSelected)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    /// Checks whether the pointer is over the row. Hover is normally tracked by
    /// mouse-entered and -exited events, but those only come when the pointer moves,
    /// not when the rows move under it (after a ✕ click removes a row, say).
    func refreshHover() {
        guard let window = view.window, window.isVisible else {
            isHovered = false
            return
        }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovered = view.bounds.contains(point)
    }

    private func render() {
        guard let row else { return }
        let rootView = ShelfItemView(row: row, isSelected: isSelected, isHovered: isHovered, isExpanded: isExpanded)
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

    /// What VoiceOver says for the row, and the actions it offers. The SwiftUI view
    /// inside is hidden from VoiceOver, so the row reads as a single element.
    private func updateAccessibility() {
        guard let row else { return }
        var label = switch row {
        case .item(let item):
            "\(item.displayName), \(item.kindDescription)"
        case .stack(_, let members):
            "Stack of \(members.count) items, \(isExpanded ? "open" : "closed")"
        case .member(let item, _):
            "\(item.displayName), \(item.kindDescription), in a stack"
        }
        if let name = row.stackName {
            label = "\(name), \(label)"
        }
        if row.isPinned {
            label += ", pinned"
        }
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(row.isStack
            ? "Press to open or close the stack. Drag to use all its items."
            : "Press to open. Drag it to wherever you need it.")
        let remove = NSAccessibilityCustomAction(name: "Remove") { [weak self] in
            MainActor.assumeIsolated { self?.onRemove() }
            return true
        }
        view.setAccessibilityCustomActions([remove])
    }
}

/// The row's root view. It claims every mouse event inside itself, so the SwiftUI view
/// never sees (and never swallows) the clicks and drags the list needs. Unhandled
/// mouse events travel up the responder chain to ShelfCollectionView.
///
/// It also reports when the pointer is over the row (for the ✕), and is the element
/// VoiceOver reads.
private final class CellContainerView: NSView {
    var onHoverChange: (Bool) -> Void = { _ in }
    var onPress: () -> Bool = { false }
    private var trackingArea: NSTrackingArea?

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

    /// Hover tracking. `.activeAlways` because the shelf's window is almost never the
    /// key window of the active app, and `.inVisibleRect` keeps the area matching the
    /// row as it moves and resizes.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange(false)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
    }
}
