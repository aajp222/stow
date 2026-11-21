import AppKit
import SwiftUI

/// What a running video, audio, GIF or download job reports its progress to: the
/// bubble that rises out of the shelf (ShelfProgressBubble), or the floating
/// progress card (VideoProgressPanel) when the shelf isn't on screen.
protocol JobProgress: AnyObject {
    func show(onCancel: @escaping () -> Void)
    func begin(_ verb: String, _ item: ShelfItem, index: Int, count: Int)
    func update(progress: Double)
    /// Everything worked. `insert` puts the results on the shelf and returns their
    /// IDs; the card calls it straight away, the bubble once it's ready to pour
    /// itself into their row.
    func finish(revealing insert: @escaping () -> [ShelfItem.ID]) async
    func close()
    /// A picture of what's being downloaded, once it's known.
    func showThumbnail(at url: URL)
}

extension JobProgress {
    func showThumbnail(at url: URL) {}
}

extension VideoProgressPanel: JobProgress {
    func finish(revealing insert: @escaping () -> [ShelfItem.ID]) async {
        _ = insert()
        await finish()
    }
}

/// A Liquid Glass bubble that wells up out of the shelf's edge, pulls free like a
/// drop leaving water, and floats beside the shelf, wobbling gently, with the
/// video's thumbnail and a progress ring. When the job is done, the ring turns into
/// a tick and the bubble pours back into the shelf, right into the row where the new
/// file appears, spreading into the row's shape as the row fades in under it.
/// Point at it for a Cancel button.
///
/// It floats above the shelf, or below it when there's more room there (a shelf at
/// the top of the screen), and follows the shelf if it moves.
final class ShelfProgressBubble: JobProgress {
    private let panel: NSPanel
    private let model = ShelfBubbleModel()
    private weak var shelfWindow: NSWindow?
    private let rowScreenFrame: (ShelfItem.ID) -> NSRect?
    private let setHiddenItems: (Set<ShelfItem.ID>) -> Void
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var isClosed = false
    private var isLeaving = false
    private var mouseTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// How far from the shelf's edge the bubble's centre floats.
    private static let rise: CGFloat = 62
    static let floatingSize: CGFloat = 62
    /// The swell on the shelf's edge that the bubble rises out of and sinks into.
    private static let neckSize = CGSize(width: 64, height: 22)

    /// Nil when the shelf isn't on screen (then the job uses the floating card).
    init?(
        shelfWindow: NSWindow?,
        rowScreenFrame: @escaping (ShelfItem.ID) -> NSRect?,
        setHiddenItems: @escaping (Set<ShelfItem.ID>) -> Void
    ) {
        guard let shelfWindow, shelfWindow.isVisible, shelfWindow.screen != nil else { return nil }
        self.shelfWindow = shelfWindow
        self.rowScreenFrame = rowScreenFrame
        self.setHiddenItems = setHiddenItems
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = shelfWindow.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own shadow.
        panel.hasShadow = false
        panel.animationBehavior = .none
        // The window covers the shelf too, so clicks go through it except on the
        // bubble itself (see trackMouse).
        panel.ignoresMouseEvents = true
        panel.contentView = BubbleHostingView(rootView: ShelfBubbleView(model: model))
        layOut()
    }

    // MARK: - Where it goes

    /// The edge of the shelf facing the bubble.
    private var edge: CGPoint {
        guard let shelf = shelfWindow?.frame else { return .zero }
        return CGPoint(x: shelf.midX, y: model.isAbove ? shelf.maxY : shelf.minY)
    }

    /// +1 when the bubble is above the shelf, -1 below (screen y runs upward).
    private var direction: CGFloat { model.isAbove ? 1 : -1 }

    private var floatPoint: CGPoint {
        CGPoint(x: edge.x, y: edge.y + direction * Self.rise)
    }

    /// Picks the side with room and sizes the window to cover the shelf and the
    /// space on both sides of it, so the bubble can move into the shelf's rows.
    private func layOut(including extra: NSRect? = nil) {
        guard let shelf = shelfWindow?.frame, let screen = shelfWindow?.screen else { return }
        let visible = screen.visibleFrame
        let needed = Self.rise + Self.floatingSize / 2 + 12
        let roomAbove = visible.maxY - shelf.maxY
        let roomBelow = shelf.minY - visible.minY
        model.isAbove = roomAbove >= needed || roomAbove >= roomBelow
        let reach = Self.rise + Self.floatingSize
        var frame = NSRect(x: shelf.midX - 90, y: shelf.minY - reach, width: 180, height: shelf.height + 2 * reach)
        if let extra {
            frame = frame.union(extra.insetBy(dx: -24, dy: -24))
        }
        frame = frame.intersection(screen.frame)
        // Moving the window and the drawing's origin together, without animating.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.windowFrame = frame }
        panel.setFrame(frame, display: true)
    }

    /// The shelf moved or changed size: follow it.
    private func shelfMoved() {
        guard !isLeaving, !isClosed else { return }
        let wasAbove = model.isAbove
        layOut()
        guard model.isFloating else { return }
        let animation: Animation? = wasAbove == model.isAbove ? nil : .spring(response: 0.6, dampingFraction: 0.7)
        withAnimation(animation) {
            model.bubbleCenter = floatPoint
        }
    }

    // MARK: - JobProgress

    func show(onCancel: @escaping () -> Void) {
        model.onCancel = onCancel
        shelfWindow?.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: shelfWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.shelfMoved() }
            })
        }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        Task { await emerge() }
    }

    func begin(_ verb: String, _ item: ShelfItem, index: Int, count: Int) {
        model.verb = verb
        model.name = item.displayName
        model.index = index
        model.count = count
        model.fraction = 0
        model.image = nil
        let name = model.name
        if item.fileURL != nil {
            // The file's own picture: a frame of the video, the cover art, the photo.
            Task {
                let scale = panel.screen?.backingScaleFactor ?? 2
                let side = Self.floatingSize
                guard let image = await ThumbnailProvider.shared.thumbnail(for: item, size: CGSize(width: side, height: side), scale: scale),
                      model.name == name, model.image == nil else { return }
                withAnimation(.easeInOut(duration: 0.4)) { model.image = image }
            }
            return
        }
        guard let url = item.linkURL else { return }
        Task {
            // YouTube's thumbnails can be fetched at once; other sites' come
            // through showThumbnail once yt-dlp has looked the page up.
            guard let image = await MediaDownload.quickThumbnail(for: url), model.name == name, model.image == nil else { return }
            withAnimation(.easeInOut(duration: 0.4)) { model.image = image }
        }
    }

    func showThumbnail(at url: URL) {
        guard model.image == nil else { return }
        let name = model.name
        Task {
            // Unless the job has moved on meanwhile.
            guard let image = await MediaDownload.image(at: url), model.name == name, model.image == nil else { return }
            withAnimation(.easeInOut(duration: 0.4)) { model.image = image }
        }
    }

    func update(progress: Double) {
        model.fraction = progress
    }

    func finish(revealing insert: @escaping () -> [ShelfItem.ID]) async {
        withAnimation(.bouncy(duration: 0.45)) { model.isFinished = true }
        try? await Task.sleep(for: .seconds(0.6))
        isLeaving = true
        let ids = insert()
        setHiddenItems(Set(ids))
        // Let the shelf lay out the new rows (and grow) before asking where they are.
        try? await Task.sleep(for: .milliseconds(80))
        if let id = ids.first, let target = rowScreenFrame(id), !reduceMotion {
            await pour(into: target)
        } else {
            await sinkBack()
        }
        setHiddenItems([])
        remove()
    }

    func close() {
        guard !isClosed, !isLeaving else { return }
        // Cancelled or failed: sink back without the tick.
        isLeaving = true
        Task {
            await sinkBack()
            remove()
        }
    }

    // MARK: - Animations

    /// Out of the shelf: a swell on the edge, the bubble pulling up out of it
    /// (stretched, still joined), then breaking free and settling with a wobble.
    private func emerge() async {
        let start = CGPoint(x: edge.x, y: edge.y - direction * 6)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.neckCenter = edge
            model.neckSize = .zero
            model.bubbleCenter = start
            model.bubbleSize = CGSize(width: 20, height: 20)
            model.contentOpacity = 0
            model.bubbleOpacity = reduceMotion ? 0 : 1
        }
        // One frame, so SwiftUI draws that starting point before animating from it.
        try? await Task.sleep(for: .milliseconds(30))

        if reduceMotion {
            withTransaction(transaction) {
                model.bubbleCenter = floatPoint
                model.bubbleSize = CGSize(width: Self.floatingSize, height: Self.floatingSize)
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                model.bubbleOpacity = 1
                model.contentOpacity = 1
            }
            model.isFloating = true
            return
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            model.neckSize = Self.neckSize
        }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            model.bubbleCenter = CGPoint(x: edge.x, y: edge.y + direction * 26)
            model.bubbleSize = CGSize(width: 36, height: 52)
        }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.spring(response: 0.65, dampingFraction: 0.52)) {
            model.bubbleCenter = floatPoint
            model.bubbleSize = CGSize(width: Self.floatingSize, height: Self.floatingSize)
        }
        withAnimation(.easeIn(duration: 0.32)) {
            model.neckSize = .zero
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.12)) {
            model.contentOpacity = 1
        }
        try? await Task.sleep(for: .milliseconds(450))
        if !isLeaving {
            model.floatingSince = Date()
            model.isFloating = true
        }
    }

    /// Into the shelf, into the new file's row: a little lift, a swell on the edge to
    /// catch it, a stretched fall into the row, then it spreads into the row's shape
    /// and dissolves as the row fades in.
    private func pour(into target: NSRect) async {
        model.isFloating = false
        layOut(including: target)
        let entry = CGPoint(x: target.midX, y: edge.y)

        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            model.bubbleCenter.y += direction * 8
            model.bubbleSize = CGSize(width: 68, height: 54)
        }
        try? await Task.sleep(for: .milliseconds(170))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.neckCenter = entry }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            model.neckSize = Self.neckSize
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            model.bubbleCenter = CGPoint(x: target.midX, y: target.midY)
            model.bubbleSize = CGSize(width: 46, height: 74)
        }
        withAnimation(.easeOut(duration: 0.2)) {
            model.ringOpacity = 0
        }
        try? await Task.sleep(for: .milliseconds(220))
        withAnimation(.easeIn(duration: 0.35)) {
            model.neckSize = .zero
        }
        try? await Task.sleep(for: .milliseconds(140))
        let shape = target.insetBy(dx: 4, dy: 4)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.66)) {
            model.bubbleSize = shape.size
            model.cornerRadius = 16
        }
        try? await Task.sleep(for: .milliseconds(320))
        setHiddenItems([])
        withAnimation(.easeOut(duration: 0.35)) {
            model.bubbleOpacity = 0
        }
        try? await Task.sleep(for: .milliseconds(380))
    }

    /// Back into the shelf's edge where it came from (Cancel, a failure, or a result
    /// whose row isn't on screen).
    private func sinkBack() async {
        model.isFloating = false
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { model.bubbleOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(280))
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.neckCenter = edge }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            model.neckSize = Self.neckSize
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            model.bubbleCenter = CGPoint(x: edge.x, y: edge.y - direction * 6)
            model.bubbleSize = CGSize(width: 20, height: 20)
            model.contentOpacity = 0
        }
        try? await Task.sleep(for: .milliseconds(330))
        withAnimation(.easeIn(duration: 0.3)) {
            model.neckSize = .zero
        }
        try? await Task.sleep(for: .milliseconds(340))
    }

    // MARK: - Mouse and cleanup

    /// Lets clicks reach the window only while the pointer is over the floating
    /// bubble, and shows Cancel then. Also brings the bubble back if the shelf was
    /// hidden and shown again.
    private func trackMouse() {
        if let shelfWindow, shelfWindow.isVisible, !panel.isVisible, !isClosed {
            shelfWindow.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        let mouse = NSEvent.mouseLocation
        let center = model.bubbleCenter
        let inside = model.isFloating && !model.isFinished
            && hypot(mouse.x - center.x, mouse.y - center.y) <= model.bubbleSize.width / 2 + 2
        panel.ignoresMouseEvents = !inside
        if model.isHovering != inside {
            withAnimation(.easeInOut(duration: 0.15)) { model.isHovering = inside }
        }
    }

    private func remove() {
        guard !isClosed else { return }
        isClosed = true
        mouseTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        shelfWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

@Observable
final class ShelfBubbleModel {
    /// The panel's frame; everything below is in screen coordinates.
    var windowFrame = NSRect.zero
    var isAbove = true
    var bubbleCenter = CGPoint.zero
    var bubbleSize = CGSize(width: 20, height: 20)
    /// Nil keeps it round; a number makes it a rounded rectangle (a row's shape).
    var cornerRadius: CGFloat?
    var neckCenter = CGPoint.zero
    var neckSize = CGSize.zero
    var bubbleOpacity = 1.0
    var contentOpacity = 0.0
    var ringOpacity = 1.0
    /// Floating beside the shelf: it wobbles and bobs, and can be pointed at.
    var isFloating = false
    var floatingSince: Date?
    var isHovering = false

    var image: NSImage?
    var verb = ""
    var name = ""
    var index = 0
    var count = 1
    var fraction = 0.0
    var isFinished = false
    var onCancel: () -> Void = {}

    var overallFraction: Double {
        isFinished ? 1 : (Double(index) + fraction) / Double(max(count, 1))
    }

    /// 0...1: the wobble eases in over the first moment of floating.
    func wobble(at date: Date) -> Double {
        guard isFloating, let since = floatingSince else { return 0 }
        return min(max(date.timeIntervalSince(since) / 0.8, 0), 1)
    }

    /// A point in screen coordinates, in the panel's SwiftUI coordinates.
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - windowFrame.minX, y: windowFrame.maxY - point.y)
    }
}

/// The bubble and the swell on the shelf's edge, both glass inside one
/// GlassEffectContainer. The container melts glass shapes together while they're
/// close and lets them split as they part, which is what makes it look like liquid;
/// the bubble also keeps changing shape a little while it floats.
struct ShelfBubbleView: View {
    let model: ShelfBubbleModel

    var body: some View {
        TimelineView(.animation(paused: !model.isFloating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let wobble = model.wobble(at: context.date)
            // Breathing out of step in width and height reads as jelly, not a ball.
            let size = CGSize(
                width: model.bubbleSize.width * (1 + 0.04 * wobble * sin(time * 2.4)),
                height: model.bubbleSize.height * (1 + 0.04 * wobble * sin(time * 2.4 + .pi * 0.85))
            )
            let bob = 2.5 * wobble * sin(time * 1.7)
            let corner = model.cornerRadius ?? min(size.width, size.height) / 2
            let center = model.local(model.bubbleCenter)

            GlassEffectContainer(spacing: 30) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: model.neckSize.width, height: model.neckSize.height)
                        .glassEffect(.regular, in: Capsule())
                        .position(model.local(model.neckCenter))
                    bubble(size: size, corner: corner)
                        .frame(width: size.width, height: size.height)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                        .position(x: center.x, y: center.y + bob)
                        .opacity(model.bubbleOpacity)
                }
                .frame(width: model.windowFrame.width, height: model.windowFrame.height, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.verb) \(model.name)")
        .accessibilityValue("\(Int(model.overallFraction * 100)) percent")
        .accessibilityAction(named: "Cancel") { model.onCancel() }
    }

    private func bubble(size: CGSize, corner: CGFloat) -> some View {
        let inset: CGFloat = 3
        let hasImage = model.image != nil
        return ZStack {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: max(size.width - inset * 2, 0), height: max(size.height - inset * 2, 0))
                    .clipShape(RoundedRectangle(cornerRadius: max(corner - inset, 0), style: .continuous))
                    .transition(.opacity)
            }
            ZStack {
                Circle()
                    .stroke(hasImage ? AnyShapeStyle(.black.opacity(0.3)) : AnyShapeStyle(.quaternary), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: model.isFinished ? 1 : max(model.overallFraction, 0.004))
                    .stroke(
                        model.isFinished ? AnyShapeStyle(.green) : (hasImage ? AnyShapeStyle(.white) : AnyShapeStyle(.tint)),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(hasImage ? 0.35 : 0), radius: 2)
            }
            .padding(7)
            .opacity(model.ringOpacity)
            .animation(.smooth(duration: 0.35), value: model.fraction)
            center(hasImage: hasImage)
        }
        .opacity(model.contentOpacity)
        .help(helpText)
    }

    @ViewBuilder
    private func center(hasImage: Bool) -> some View {
        if model.isFinished {
            ZStack {
                Circle().fill(.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .opacity(model.ringOpacity)
            .transition(.scale.combined(with: .opacity))
        } else if model.isHovering {
            Button(action: model.onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.5), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .transition(.opacity)
        } else if !hasImage {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)
        }
    }

    /// What's shown in the middle until there's a picture.
    private var symbol: String {
        switch model.verb {
        case "Getting", "Downloading": "arrow.down"
        case "Making GIF": "photo.stack"
        case "Trimming": "scissors"
        default: "arrow.triangle.2.circlepath"
        }
    }

    /// "Downloading “Song Title” · 2 of 3 · 42%"
    private var helpText: String {
        var parts = ["\(model.verb) “\(model.name)”"]
        if model.count > 1 {
            parts.append("\(model.index + 1) of \(model.count)")
        }
        parts.append("\(Int(model.fraction * 100))%")
        return parts.joined(separator: " · ")
    }
}

/// The bubble's window never becomes key, so without this the first click on
/// Cancel would only "wake" the window.
private final class BubbleHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
