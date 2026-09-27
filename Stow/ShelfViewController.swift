import AppKit
import Observation
import QuartzCore

/// Sizes shared by the shelf's view and the panel that holds it.
enum ShelfLayout {
    static let width: CGFloat = 120
    static let cornerRadius: CGFloat = 20
    /// Gap between the shelf and the screen edge it's docked to.
    static let screenMargin: CGFloat = 8
    static let headerHeight: CGFloat = 28
    static let itemHeight: CGFloat = 108
    static let itemSpacing: CGFloat = 4
    static let sectionInset = NSEdgeInsets(top: 2, left: 8, bottom: 8, right: 8)
    static let emptyHeight: CGFloat = 150

    /// Height that fits `rowCount` rows without scrolling. The panel passes at most
    /// the "Items shown before scrolling" setting, caps the result at 70% of the
    /// screen, and the list scrolls beyond that.
    static func contentHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return emptyHeight }
        let count = CGFloat(rowCount)
        return headerHeight + sectionInset.top + count * itemHeight + (count - 1) * itemSpacing + sectionInset.bottom
    }

    /// Where a row's ✕ can be clicked: its top-left corner, a little larger than the
    /// ✕ itself. `row` is the row's frame in the list, whose coordinates run top-down.
    static func removeButtonRect(inRow row: NSRect) -> NSRect {
        NSRect(x: row.minX, y: row.minY, width: 24, height: 24)
    }
}

/// The shelf's contents: header, item list, empty state, and drag in/out handling.
final class ShelfViewController: NSViewController {
    let viewModel: ShelfViewModel

    /// The hide button was clicked.
    var onHide: () -> Void = {}
    /// The number of rows changed, so the panel may need a new height.
    var onContentChanged: () -> Void = {}
    /// A drag out of the shelf finished (dropped, cancelled or flicked away).
    var onDragOutEnded: () -> Void = {}
    /// The user dragged the shelf to a new spot.
    var onMoved: () -> Void = {}

    private let dropView = ShelfDropView()
    /// Liquid Glass background. Everything visible sits inside its `contentView`.
    private let glassView = NSGlassEffectView()
    private let content = ShelfContentView()
    private let collectionView = ShelfCollectionView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let emptyState = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let highlightView = NSView()
    /// The line showing where dragged items will land when you reorder them.
    private let insertionIndicator = NSView()

    /// Builds the right-click menus and runs their commands.
    private lazy var contextMenus = ShelfContextMenu(viewModel: viewModel)
    private let dragSource = ShelfDragSource()

    /// The rows the list is currently showing, built from `viewModel.items`.
    private var rows: [ShelfRow] = []
    /// The items shown at the last reload, to spot newly added ones.
    private var displayedItemIDs: Set<ShelfItem.ID> = []
    /// Stacks that are fanned open.
    private var expandedStacks: Set<UUID> = []
    /// What you've typed to filter the shelf by name.
    private var filter = ""

    /// How many rows the list has, which sets the panel's height.
    var rowCount: Int { rows.count }

    init(viewModel: ShelfViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View setup

    override func loadView() {
        dropView.frame = NSRect(x: 0, y: 0, width: ShelfLayout.width, height: ShelfLayout.emptyHeight)
        configureDropView()
        configureGlassBackground()
        let hideButton = makeHideButton()
        configureTitleLabel()
        configureCollectionView()
        configureEmptyState()
        configureHighlight()
        configureInsertionIndicator()

        for subview in [glassView, highlightView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            dropView.addSubview(subview)
        }
        for subview in [titleLabel, hideButton, scrollView, emptyState] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        // Placed by frame, on top of the list.
        content.addSubview(insertionIndicator)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            glassView.topAnchor.constraint(equalTo: dropView.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            content.topAnchor.constraint(equalTo: glassView.topAnchor),
            content.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),

            hideButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            hideButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            hideButton.widthAnchor.constraint(equalToConstant: 18),
            hideButton.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: hideButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: hideButton.leadingAnchor, constant: -4),

            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: ShelfLayout.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -6),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -20),

            highlightView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            highlightView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            highlightView.topAnchor.constraint(equalTo: dropView.topAnchor),
            highlightView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
        ])

        view = dropView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
        observeItems()
    }

    private func configureDropView() {
        dropView.onDrop = { [weak self] incoming in
            self?.viewModel.add(incoming)
        }
        dropView.onTargetedChange = { [weak self] isTargeted in
            self?.setDropTargeted(isTargeted)
        }
        // A drag this shelf started is a reorder, not new items arriving.
        dropView.isInternal = { [weak self] info in
            guard let self else { return false }
            return (info.draggingSource as? ShelfDragSource) === self.dragSource
        }
        dropView.onInternalMove = { [weak self] point in self?.internalDragMoved(to: point) }
        dropView.onInternalDrop = { [weak self] point in self?.internalDrop(at: point) ?? false }
        dropView.onInternalEnd = { [weak self] in self?.insertionIndicator.isHidden = true }

        dragSource.onEnded = { [weak self] ids, operation, endPoint, droppedOnShelf in
            self?.dragEnded(ids: ids, operation: operation, at: endPoint, droppedOnShelf: droppedOnShelf)
        }
        dragSource.shelfFrame = { [weak self] in self?.flickSafeFrame ?? .zero }
    }

    /// Sets up the Liquid Glass background (macOS 26's `NSGlassEffectView`) and puts
    /// `content`, the view the shelf's controls go in, inside it.
    ///
    /// The glass refracts and tints whatever is behind the window, and adapts its
    /// own brightness so the content on top stays readable. Only views inside its
    /// `contentView` are guaranteed to get that treatment, so everything visible goes
    /// in there instead of being layered on top.
    private func configureGlassBackground() {
        glassView.cornerRadius = ShelfLayout.cornerRadius
        content.onMoved = { [weak self] in self?.onMoved() }
        content.menuProvider = { [weak self] in self?.contextMenus.menu(for: []) }
        content.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = content
    }

    /// While files hover over the shelf: tint the glass with the accent colour and
    /// show an outline.
    private func setDropTargeted(_ isTargeted: Bool) {
        glassView.tintColor = isTargeted ? NSColor.controlAccentColor.withAlphaComponent(0.25) : nil
        highlightView.isHidden = !isTargeted
    }

    private func makeHideButton() -> NSButton {
        let button = FirstMouseButton()
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide Shelf")
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = "Hide Shelf"
        button.target = self
        button.action = #selector(hideClicked)
        return button
    }

    private func configureTitleLabel() {
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
    }

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.itemSize = NSSize(width: ShelfLayout.width - 16, height: ShelfLayout.itemHeight)
        layout.minimumLineSpacing = ShelfLayout.itemSpacing
        layout.minimumInteritemSpacing = ShelfLayout.itemSpacing
        layout.sectionInset = ShelfLayout.sectionInset

        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.register(ShelfItemCell.self, forItemWithIdentifier: ShelfItemCell.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.setAccessibilityLabel("Shelf")
        collectionView.contextMenuProvider = { [weak self] onItem in
            guard let self else { return nil }
            return self.contextMenus.menu(for: onItem ? self.selectedItems : [])
        }
        collectionView.selectedFileURLs = { [weak self] in
            self?.selectedItems.compactMap { $0.fileURL } ?? []
        }
        collectionView.onWindowMoved = { [weak self] in self?.onMoved() }
        collectionView.onBeginDrag = { [weak self] event in self?.beginDrag(with: event) }
        collectionView.onClickRow = { [weak self] indexPath in self?.clicked(indexPath) }
        collectionView.onDoubleClickRow = { [weak self] indexPath in self?.doubleClicked(indexPath) }
        collectionView.onRemoveRow = { [weak self] indexPath in self?.removeRow(at: indexPath) }
        collectionView.onOpen = { [weak self] in self?.openSelection() }
        collectionView.onDeleteKey = { [weak self] in self?.deletePressed() }
        collectionView.onEscape = { [weak self] in self?.escapePressed() }
        collectionView.onCopy = { [weak self] in self?.copySelection() }
        collectionView.onType = { [weak self] text in self?.typed(text) }
        collectionView.onExpand = { [weak self] open in self?.setSelectedStacksExpanded(open) }
        collectionView.autoresizingMask = [.width]

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func configureEmptyState() {
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 6
        emptyState.addArrangedSubview(emptyIcon)
        emptyState.addArrangedSubview(emptyLabel)
    }

    /// Accent-coloured outline shown while a drag hovers over the shelf.
    private func configureHighlight() {
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = ShelfLayout.cornerRadius
        highlightView.layer?.borderWidth = 2
        highlightView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlightView.isHidden = true
    }

    private func configureInsertionIndicator() {
        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionIndicator.layer?.cornerRadius = 1
        insertionIndicator.isHidden = true
    }

    // MARK: - Keeping in sync with the view model

    /// Reloads the list whenever `viewModel.items` changes.
    ///
    /// `withObservationTracking` records which observable properties the first
    /// closure reads, then calls `onChange` once, just *before* one of them changes.
    /// It's one-shot, so we re-arm it after each change. And since the new value
    /// isn't stored yet when `onChange` runs, the reload waits for the next turn of
    /// the main run loop.
    private func observeItems() {
        withObservationTracking {
            _ = viewModel.items
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
                self?.observeItems()
            }
        }
    }

    /// Rebuilds the rows from the items. Rows whose IDs are in `selecting` end up
    /// selected; by default, whatever was selected stays selected.
    private func reload(selecting: Set<UUID>? = nil) {
        let selectedIDs = selecting ?? Set(selectedRows.map { $0.id })
        let items = viewModel.items
        // Forget open stacks that no longer exist.
        expandedStacks.formIntersection(Set(items.compactMap { $0.stackID }))
        rows = ShelfRow.rows(for: items, expanded: expandedStacks, filter: filter)
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(
            rows.indices
                .filter { selectedIDs.contains(rows[$0].id) }
                .map { IndexPath(item: $0, section: 0) }
        )

        updateTitle()
        updateEmptyState()
        onContentChanged()

        // New items go at the end. Once the list scrolls, scroll down to the newest
        // one so you can see what you just added.
        let previousIDs = displayedItemIDs
        displayedItemIDs = Set(items.map { $0.id })
        if !previousIDs.isEmpty,
           let newest = items.last(where: { !previousIDs.contains($0.id) }),
           let row = rows.firstIndex(where: { $0.items.contains { $0.id == newest.id } }) {
            collectionView.scrollToItems(at: [IndexPath(item: row, section: 0)], scrollPosition: .bottom)
        }

        // Rows under the pointer changed without it moving, so the ✕ has to follow.
        collectionView.layoutSubtreeIfNeeded()
        for case let cell as ShelfItemCell in collectionView.visibleItems() {
            cell.refreshHover()
        }
    }

    private func updateTitle() {
        guard !filter.isEmpty else {
            let count = viewModel.items.count
            titleLabel.stringValue = count == 0 ? "Stow" : (count == 1 ? "1 item" : "\(count) items")
            // Undo the filter's styling.
            titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.setAccessibilityLabel(nil)
            return
        }
        // While you type, the title shows what you're filtering by.
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " " + filter))
        text.addAttributes(
            [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor],
            range: NSRange(location: 0, length: text.length)
        )
        titleLabel.attributedStringValue = text
        titleLabel.setAccessibilityLabel("Filtering by \(filter)")
    }

    private func updateEmptyState() {
        emptyState.isHidden = !rows.isEmpty
        let noMatches = !viewModel.items.isEmpty
        emptyIcon.image = NSImage(systemSymbolName: noMatches ? "magnifyingglass" : "tray.and.arrow.down", accessibilityDescription: nil)
        emptyLabel.stringValue = noMatches ? "No matches" : "Drop files here"
    }

    /// The selected rows, top to bottom.
    private var selectedRows: [ShelfRow] {
        collectionView.selectionIndexPaths
            .sorted()
            .compactMap { rows.indices.contains($0.item) ? rows[$0.item] : nil }
    }

    /// The items the selection stands for (a stack stands for all its members), in
    /// shelf order, each once.
    private var selectedItems: [ShelfItem] {
        var seen = Set<ShelfItem.ID>()
        return selectedRows.flatMap { $0.items }.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Clicks

    @objc private func hideClicked() {
        onHide()
    }

    /// Clicking a stack fans it open, or closes it again.
    private func clicked(_ indexPath: IndexPath) {
        guard rows.indices.contains(indexPath.item), case .stack(let id, _) = rows[indexPath.item] else { return }
        toggleStack(id)
    }

    /// Double-clicking an item opens it, like in Finder. (A stack already opened on
    /// the first click.)
    private func doubleClicked(_ indexPath: IndexPath) {
        guard rows.indices.contains(indexPath.item), !rows[indexPath.item].isStack else { return }
        open(rows[indexPath.item].items)
    }

    /// The ✕ in a row's corner, or VoiceOver's Remove action.
    private func removeRow(at indexPath: IndexPath) {
        guard rows.indices.contains(indexPath.item) else { return }
        viewModel.remove(Set(rows[indexPath.item].items.map { $0.id }))
    }

    private func toggleStack(_ id: UUID) {
        if expandedStacks.remove(id) == nil {
            expandedStacks.insert(id)
        }
        reload()
    }

    private func open(_ items: [ShelfItem]) {
        if !ShelfContextMenu.open(items) {
            NSSound.beep()
        }
    }

    // MARK: - Keyboard

    /// Return: open the selected items, or open and close a selected stack.
    private func openSelection() {
        let selected = selectedRows
        if selected.count == 1, case .stack(let id, _) = selected[0] {
            toggleStack(id)
        } else if selected.isEmpty {
            NSSound.beep()
        } else {
            open(selectedItems)
        }
    }

    /// Delete takes back a typed letter while filtering, and otherwise removes the
    /// selected items.
    private func deletePressed() {
        if !filter.isEmpty {
            filter.removeLast()
            reload()
        } else if !selectedItems.isEmpty {
            viewModel.remove(Set(selectedItems.map { $0.id }))
        } else {
            NSSound.beep()
        }
    }

    /// Esc clears the filter, or else the selection.
    private func escapePressed() {
        if !filter.isEmpty {
            clearFilter()
        } else {
            collectionView.deselectAll(nil)
        }
    }

    private func copySelection() {
        let items = selectedItems
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        ShelfContextMenu.copy(items)
    }

    /// Typing filters the shelf to items whose names contain what you typed, and
    /// selects the first match.
    private func typed(_ text: String) {
        filter += text
        reload(selecting: [])
        if !rows.isEmpty {
            let first = IndexPath(item: rows.firstIndex { !$0.isStack } ?? 0, section: 0)
            collectionView.selectionIndexPaths = [first]
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
    }

    /// Shows everything again. Called by Esc, and when the shelf hides.
    func clearFilter() {
        guard !filter.isEmpty else { return }
        filter = ""
        reload()
    }

    /// → opens the selected stacks and ← closes them (← on an item in an open stack
    /// closes that stack and selects it).
    private func setSelectedStacksExpanded(_ open: Bool) {
        var select: Set<UUID> = []
        for row in selectedRows {
            switch row {
            case .stack(let id, _):
                if open {
                    expandedStacks.insert(id)
                } else {
                    expandedStacks.remove(id)
                }
                select.insert(id)
            case .member(_, let stackID) where !open:
                expandedStacks.remove(stackID)
                select.insert(stackID)
            default:
                select.insert(row.id)
            }
        }
        reload(selecting: select)
    }

    /// Gives the list the keyboard, so the arrow keys and typing work straight away.
    /// Used when the shelf is shown with the keyboard shortcut. The panel doesn't
    /// activate Stow, so the app you were in stays frontmost.
    func focusList() {
        guard let window = view.window else { return }
        window.makeKey()
        window.makeFirstResponder(collectionView)
        if collectionView.selectionIndexPaths.isEmpty, !rows.isEmpty {
            collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        }
    }

    // MARK: - Dragging items out

    /// Starts dragging the selected rows. NSCollectionView could run this drag by
    /// itself, but only with one pasteboard item per row, and a stack row needs one
    /// per file. So the shelf starts the session itself, with ShelfDragSource as its
    /// source.
    private func beginDrag(with event: NSEvent) {
        var draggingItems: [NSDraggingItem] = []
        var ids: [ShelfItem.ID] = []
        var detached: Set<ShelfItem.ID> = []
        var seen = Set<ShelfItem.ID>()
        for indexPath in collectionView.selectionIndexPaths.sorted() {
            guard rows.indices.contains(indexPath.item),
                  let rowFrame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { continue }
            let row = rows[indexPath.item]
            for (offset, item) in row.items.enumerated() where seen.insert(item.id).inserted {
                ids.append(item.id)
                // An item dragged out of an open stack on its own leaves the stack if
                // it's dropped back on the shelf.
                if row.isMember {
                    detached.insert(item.id)
                }
                // Each of a stack's files gets its own picture, fanned out a little.
                let fan = CGFloat(min(offset, 4)) * 4
                let draggingItem = NSDraggingItem(pasteboardWriter: item.pasteboardWriter)
                let image = ThumbnailProvider.shared.cachedThumbnail(for: item) ?? ThumbnailProvider.shared.icon(for: item)
                draggingItem.setDraggingFrame(Self.previewFrame(inRow: rowFrame, fitting: image.size).offsetBy(dx: fan, dy: fan), contents: image)
                draggingItems.append(draggingItem)
            }
        }
        guard !draggingItems.isEmpty else { return }

        dragSource.begin(itemIDs: ids, detachedIDs: detached)
        let session = collectionView.beginDraggingSession(with: draggingItems, event: event, source: dragSource)
        session.draggingFormation = draggingItems.count > 1 ? .pile : .none
    }

    /// Where ShelfItemView draws a row's 64×64 preview (6 pt from the top, centred),
    /// narrowed to the image's aspect ratio. In the list's top-down coordinates.
    private static func previewFrame(inRow row: NSRect, fitting imageSize: NSSize) -> NSRect {
        let side: CGFloat = 64
        let box = NSRect(x: row.midX - side / 2, y: row.minY + 6, width: side, height: side)
        guard imageSize.width > 0, imageSize.height > 0 else { return box }
        let scale = min(side / imageSize.width, side / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Around the shelf, in screen coordinates. Items let go in here are never
    /// flicked away; they slide back if nothing takes them.
    private var flickSafeFrame: NSRect {
        view.window?.frame.insetBy(dx: -60, dy: -60) ?? .zero
    }

    /// A drag out of the shelf finished.
    ///
    /// `operation` is what the drop target did with the items, or empty if nothing
    /// took them. Items let go well away from the shelf where nothing takes them are
    /// "flicked off": they vanish in a puff of smoke (Restore Last Removed Files
    /// brings them back). Pressing Esc cancels the drag with the mouse button still
    /// down, which removes nothing.
    private func dragEnded(ids: [ShelfItem.ID], operation: NSDragOperation, at endPoint: NSPoint, droppedOnShelf: Bool) {
        insertionIndicator.isHidden = true
        defer { onDragOutEnded() }
        // Dropped back on the shelf: that was a reorder, already done.
        guard !droppedOnShelf else { return }
        if operation.isEmpty {
            let released = NSEvent.pressedMouseButtons & 1 == 0
            if released, !flickSafeFrame.contains(endPoint) {
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    PuffOfSmoke.show(at: endPoint)
                }
                viewModel.remove(Set(ids))
            }
            return
        }
        viewModel.finishDragOut(of: ids, operation: operation)
    }

    // MARK: - Reordering

    /// The shelf's own items are being dragged over it: show where they'd land, and
    /// scroll when the pointer nears the top or bottom of the list.
    private func internalDragMoved(to windowPoint: NSPoint) {
        autoscroll(at: windowPoint)
        let index = insertionIndex(at: windowPoint)
        let y: CGFloat
        if index < rows.count, let frame = rowFrame(at: index) {
            y = frame.minY - ShelfLayout.itemSpacing / 2
        } else if let frame = rowFrame(at: rows.count - 1) {
            y = frame.maxY + ShelfLayout.itemSpacing / 2
        } else {
            insertionIndicator.isHidden = true
            return
        }
        let inset = ShelfLayout.sectionInset
        let line = NSRect(x: inset.left + 4, y: y - 1, width: collectionView.bounds.width - inset.left - inset.right - 8, height: 2)
        let frame = content.convert(line, from: collectionView)
        insertionIndicator.frame = frame
        insertionIndicator.isHidden = !scrollView.frame.intersects(frame)
    }

    /// The shelf's own items were dropped on it: move them to the insertion point.
    private func internalDrop(at windowPoint: NSPoint) -> Bool {
        insertionIndicator.isHidden = true
        let ids = dragSource.itemIDs
        guard !ids.isEmpty else { return false }
        let moving = Set(ids)
        let index = insertionIndex(at: windowPoint)
        // They go just before the first item at the insertion point that isn't itself
        // being moved, or at the end.
        let target = rows[index...].lazy.flatMap { $0.items }.first { !moving.contains($0.id) }
        dragSource.droppedOnShelf = true
        viewModel.reorder(ids, before: target?.id, detaching: dragSource.detachedIDs)
        return true
    }

    /// Which row dropped items would go in front of (`rows.count` means the end).
    /// Never between the rows of an open stack: those land after the stack.
    private func insertionIndex(at windowPoint: NSPoint) -> Int {
        let point = collectionView.convert(windowPoint, from: nil)
        var index = rows.indices.first { index in
            guard let frame = rowFrame(at: index) else { return false }
            return point.y < frame.midY
        } ?? rows.count
        while index < rows.count, rows[index].isMember {
            index += 1
        }
        return index
    }

    private func rowFrame(at index: Int) -> NSRect? {
        guard rows.indices.contains(index) else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
    }

    /// Scrolls the list a little while a reorder drag hovers near its top or bottom.
    /// The drop view is told about the drag every few moments even when the pointer
    /// holds still, so this keeps scrolling until you move away from the edge.
    private func autoscroll(at windowPoint: NSPoint) {
        let clipView = scrollView.contentView
        let point = clipView.convert(windowPoint, from: nil)
        let bounds = clipView.bounds
        let edge: CGFloat = 24
        var origin = bounds.origin
        // The clip view shares the list's top-down coordinates.
        if point.y < bounds.minY + edge {
            origin.y -= 8
        } else if point.y > bounds.maxY - edge {
            origin.y += 8
        } else {
            return
        }
        origin.y = min(max(origin.y, 0), max(collectionView.frame.height - bounds.height, 0))
        guard origin != bounds.origin else { return }
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}

// MARK: - NSCollectionViewDataSource

extension ShelfViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ShelfItemCell.identifier, for: indexPath)
        guard let cell = item as? ShelfItemCell else { return item }
        let row = rows[indexPath.item]
        let isExpanded = if case .stack(let id, _) = row { expandedStacks.contains(id) || !filter.isEmpty } else { false }
        cell.configure(with: row, isExpanded: isExpanded)
        // Cells are reused for other rows, so these find the row by its ID.
        let rowID = row.id
        cell.onPress = { [weak self] in self?.pressed(rowID: rowID) }
        cell.onRemove = { [weak self] in
            guard let self, let index = self.rows.firstIndex(where: { $0.id == rowID }) else { return }
            self.removeRow(at: IndexPath(item: index, section: 0))
        }
        return cell
    }

    /// VoiceOver's "press" on a row: open or close a stack, open anything else.
    private func pressed(rowID: UUID) {
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        if case .stack(let id, _) = row {
            toggleStack(id)
        } else {
            open(row.items)
        }
    }
}

// MARK: - NSCollectionViewDelegateFlowLayout

extension ShelfViewController: NSCollectionViewDelegateFlowLayout {
    /// Rows fill the list's width, which shrinks a little if a scroll bar is showing.
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let inset = ShelfLayout.sectionInset
        let width = collectionView.bounds.width - inset.left - inset.right
        return NSSize(width: max(width, 60), height: ShelfLayout.itemHeight)
    }
}

/// Holds the shelf's controls inside the glass, and lets you drag the whole shelf
/// around by any part that isn't an item or the hide button.
private final class ShelfContentView: NSView {
    var onMoved: () -> Void = {}
    /// The right-click menu for the shelf itself (not an item).
    var menuProvider: () -> NSMenu? = { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The title, the empty-state picture and label, and the blank area under a
        // short list don't need clicks of their own. Route those clicks here instead,
        // so pressing on them and dragging moves the shelf.
        if hit is NSTextField || hit is NSImageView || hit is NSStackView || hit is NSClipView {
            return self
        }
        return hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if window?.followMouseDrag() == true {
            onMoved()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider()
    }
}

/// The little cloud shown where flicked-off items vanish. AppKit's own version
/// (NSAnimationEffect.poof) is deprecated, so this plays the system's "disappearing
/// item" cursor picture in a tiny window of its own, growing as it fades out.
private enum PuffOfSmoke {
    static func show(at screenPoint: NSPoint) {
        let side: CGFloat = 40
        let frame = NSRect(x: screenPoint.x - side / 2, y: screenPoint.y - side / 2, width: side, height: side)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Above the shelf and other floating windows.
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let imageView = NSImageView(image: NSCursor.disappearingItem.image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = imageView
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame.insetBy(dx: -side / 4, dy: -side / 4), display: true)
            window.animator().alphaValue = 0
        }, completionHandler: {
            // AppKit calls animation completion handlers on the main thread.
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }
}

/// A button that works on the first click, even though the shelf isn't the key window.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
