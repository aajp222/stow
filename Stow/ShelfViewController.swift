import AppKit
import Observation

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

    /// Height that fits `itemCount` items without scrolling. The panel caps this at
    /// 70% of the screen and the list scrolls beyond that.
    static func contentHeight(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return emptyHeight }
        let count = CGFloat(itemCount)
        return headerHeight + sectionInset.top + count * itemHeight + (count - 1) * itemSpacing + sectionInset.bottom
    }
}

/// The shelf's contents: header, item list, empty state, and drag in/out handling.
final class ShelfViewController: NSViewController {
    let viewModel: ShelfViewModel

    /// The hide button was clicked.
    var onHide: () -> Void = {}
    /// The number of items changed, so the panel may need a new height.
    var onContentChanged: () -> Void = {}
    /// A drag out of the shelf finished (dropped or cancelled).
    var onDragOutEnded: () -> Void = {}

    private let dropView = ShelfDropView()
    /// Liquid Glass background. Everything visible sits inside its `contentView`.
    private let glassView = NSGlassEffectView()
    private let collectionView = ShelfCollectionView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let emptyState = NSStackView()
    private let highlightView = NSView()

    /// The snapshot of `viewModel.items` the collection view is currently showing.
    private var displayedItems: [ShelfItem] = []
    private var draggedItemIDs: [ShelfItem.ID] = []

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
        dropView.shouldAccept = { [weak self] info in
            // Ignore the shelf's own items being dragged back onto it.
            guard let self, let source = info.draggingSource as? NSView else { return true }
            return source !== self.collectionView
        }
        dropView.onDrop = { [weak self] fileURLs, promises in
            self?.viewModel.addFiles(fileURLs)
            self?.viewModel.receive(promises)
        }
        dropView.onTargetedChange = { [weak self] isTargeted in
            self?.setDropTargeted(isTargeted)
        }

        let content = makeGlassBackground()
        let hideButton = makeHideButton()
        configureTitleLabel()
        configureCollectionView()
        configureEmptyState()
        configureHighlight()

        for subview in [glassView, highlightView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            dropView.addSubview(subview)
        }
        for subview in [titleLabel, hideButton, scrollView, emptyState] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
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

    /// Sets up the Liquid Glass background (macOS 26's `NSGlassEffectView`) and
    /// returns the view the shelf's controls go in.
    ///
    /// The glass refracts and tints whatever is behind the window, and adapts its
    /// own brightness so the content on top stays readable. Only views inside its
    /// `contentView` are guaranteed to get that treatment, so everything visible goes
    /// in there instead of being layered on top.
    private func makeGlassBackground() -> NSView {
        glassView.cornerRadius = ShelfLayout.cornerRadius
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = content
        return content
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
        collectionView.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        collectionView.autoresizingMask = [.width]

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func configureEmptyState() {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        let label = NSTextField(wrappingLabelWithString: "Drop files here")
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 6
        emptyState.addArrangedSubview(icon)
        emptyState.addArrangedSubview(label)
    }

    /// Accent-coloured outline shown while a drag hovers over the shelf.
    private func configureHighlight() {
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = ShelfLayout.cornerRadius
        highlightView.layer?.borderWidth = 2
        highlightView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlightView.isHidden = true
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

    private func reload() {
        // Keep the same items selected across the reload.
        let selectedIDs = Set(selectedItems.map { $0.id })
        displayedItems = viewModel.items
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(
            displayedItems.indices
                .filter { selectedIDs.contains(displayedItems[$0].id) }
                .map { IndexPath(item: $0, section: 0) }
        )

        let count = displayedItems.count
        titleLabel.stringValue = count == 0 ? "Stow" : (count == 1 ? "1 item" : "\(count) items")
        emptyState.isHidden = count > 0
        onContentChanged()
    }

    private var selectedItems: [ShelfItem] {
        collectionView.selectionIndexPaths
            .sorted()
            .compactMap { displayedItems.indices.contains($0.item) ? displayedItems[$0.item] : nil }
    }

    // MARK: - Actions

    @objc private func hideClicked() {
        onHide()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelection), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let remove = NSMenuItem(title: "Remove", action: #selector(removeSelection), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func revealSelection() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedItems.compactMap { $0.fileURL })
    }

    @objc private func removeSelection() {
        viewModel.remove(Set(selectedItems.map { $0.id }))
    }
}

// MARK: - NSCollectionViewDataSource

extension ShelfViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ShelfItemCell.identifier, for: indexPath)
        (item as? ShelfItemCell)?.configure(with: displayedItems[indexPath.item])
        return item
    }
}

// MARK: - Dragging items out (NSCollectionViewDelegate)

extension ShelfViewController: NSCollectionViewDelegateFlowLayout {
    /// Items fill the list's width, which shrinks a little if a scroll bar is showing.
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let inset = ShelfLayout.sectionInset
        let width = collectionView.bounds.width - inset.left - inset.right
        return NSSize(width: max(width, 60), height: ShelfLayout.itemHeight)
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    /// What goes on the drag pasteboard for each item. NSCollectionView calls this
    /// once per dragged item, which is how several selected items drag together.
    /// A file URL is what Finder, Mail, browsers and most other apps accept.
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        displayedItems[indexPath.item].fileURL as NSURL?
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        draggedItemIDs = indexPaths.map { displayedItems[$0.item].id }
    }

    /// `operation` is what the drop target did with the items, or empty if the drag
    /// was cancelled or refused. Only a successful drop removes anything.
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        viewModel.finishDragOut(of: draggedItemIDs, operation: operation)
        draggedItemIDs = []
        onDragOutEnded()
    }
}

/// A button that works on the first click, even though the shelf isn't the key window.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
