import AppKit
import QuartzCore

/// Which side of the screen the shelf is docked to. The shelf is a tall, narrow strip,
/// so only the left and right edges make sense.
enum ShelfEdge {
    case left, right

    /// Direction that points off the screen: -1 for the left edge, +1 for the right.
    var outward: CGFloat { self == .left ? -1 : 1 }
}

/// Shows, hides, positions and animates the shelf panel.
final class ShelfPanelController {
    let viewModel: ShelfViewModel

    private let viewController: ShelfViewController
    private let panel = ShelfPanel()

    private(set) var isShown = false
    private var screen: NSScreen?
    private var edge: ShelfEdge = .right
    /// Bumped on every show and hide, so a hide animation that finishes late doesn't
    /// remove a panel that was shown again in the meantime.
    private var animationGeneration = 0
    /// Bumped for every drag, so a hide check scheduled at the end of one drag can
    /// tell that another drag has started since.
    private var dragGeneration = 0
    private var screenObserver: NSObjectProtocol?

    /// How far the shelf slides while it fades in or out.
    private let slideDistance: CGFloat = 24

    init(viewModel: ShelfViewModel) {
        self.viewModel = viewModel
        viewController = ShelfViewController(viewModel: viewModel)
        viewController.onHide = { [weak self] in self?.hide() }
        viewController.onContentChanged = { [weak self] in self?.contentChanged() }
        viewController.onDragOutEnded = { [weak self] in self?.dragEnded() }
        panel.contentView = viewController.view

        // Displays plugged in, unplugged or rearranged: re-dock so the shelf isn't
        // left off-screen or floating mid-display.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    // MARK: - Showing and hiding

    /// The menu bar's Show/Hide Shelf command.
    func toggle() {
        if isShown {
            hide()
        } else {
            show(on: Self.screenWithMouse(), edge: edge)
        }
    }

    /// Slides the shelf in at `edge` of `screen`. If it's already there, just makes
    /// sure it's the right size.
    func show(on screen: NSScreen?, edge: ShelfEdge) {
        guard let screen = screen ?? NSScreen.main else { return }
        let target = dockedFrame(on: screen, edge: edge)
        if isShown, self.edge == edge, self.screen?.displayNumber == screen.displayNumber {
            animate(to: target)
            return
        }

        self.screen = screen
        self.edge = edge
        isShown = true
        animationGeneration += 1

        // Start a little beyond the edge and fully transparent, then slide in.
        panel.setFrame(target.offsetBy(dx: edge.outward * slideDistance, dy: 0), display: false)
        panel.alphaValue = 0
        // orderFrontRegardless puts the window on screen even though Stow isn't the
        // active app, without activating Stow or making the panel key.
        panel.orderFrontRegardless()

        let panel = self.panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        animationGeneration += 1
        let generation = animationGeneration

        let panel = self.panel
        let target = panel.frame.offsetBy(dx: edge.outward * slideDistance, dy: 0)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls animation completion handlers on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Following drags

    /// A file drag started somewhere on the Mac. Bring the shelf to the display the
    /// pointer is on, at whichever side is nearer. If it's already there, it stays put.
    func fileDragBegan(at point: NSPoint) {
        dragGeneration += 1
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let edge: ShelfEdge = point.x < screen.visibleFrame.midX ? .left : .right
        show(on: screen, edge: edge)
    }

    /// A drag ended: a file drag the monitor was following, or items dragged out of
    /// the shelf. If the shelf ends up empty, hide it.
    func dragEnded() {
        dragGeneration += 1
        let generation = dragGeneration
        Task { [weak self] in
            // The drop onto the shelf and the mouse-up can arrive in either order, so
            // give a drop a moment to land before deciding the shelf is empty.
            try? await Task.sleep(for: .milliseconds(300))
            await self?.hideIfEmpty(afterDrag: generation)
        }
    }

    private func hideIfEmpty(afterDrag generation: Int) async {
        // Promised files are written by the source app after the drop, which can
        // take a while for big files. Wait for them, but give up after 10 seconds.
        let deadline = ContinuousClock.now + .seconds(10)
        while viewModel.isReceivingPromises, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Leave the shelf alone if a new drag has started since this one ended.
        guard generation == dragGeneration, viewModel.items.isEmpty else { return }
        hide()
    }

    // MARK: - Layout

    /// Where the shelf sits when docked: against `edge`, vertically centred, as tall
    /// as its items need up to 70% of the screen (the list scrolls past that).
    private func dockedFrame(on screen: NSScreen, edge: ShelfEdge) -> NSRect {
        // visibleFrame leaves out the menu bar and the Dock, so the shelf never
        // tucks underneath either of them.
        let visible = screen.visibleFrame
        let height = min(ShelfLayout.contentHeight(itemCount: viewModel.items.count), visible.height * 0.7).rounded()
        let x = switch edge {
        case .left: visible.minX + ShelfLayout.screenMargin
        case .right: visible.maxX - ShelfLayout.width - ShelfLayout.screenMargin
        }
        return NSRect(x: x, y: (visible.midY - height / 2).rounded(), width: ShelfLayout.width, height: height)
    }

    private func contentChanged() {
        guard isShown, let screen else { return }
        animate(to: dockedFrame(on: screen, edge: edge))
    }

    private func animate(to frame: NSRect) {
        guard panel.frame != frame else { return }
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            // The shadow of a transparent window is worked out from its contents, so
            // it needs refreshing after a resize.
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        })
    }

    private func screensChanged() {
        guard isShown else { return }
        let sameDisplay = NSScreen.screens.first { $0.displayNumber == screen?.displayNumber }
        guard let newScreen = sameDisplay ?? Self.screenWithMouse() else { return }
        screen = newScreen
        panel.setFrame(dockedFrame(on: newScreen, edge: edge), display: true)
    }

    /// The display the mouse pointer is on.
    static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

private extension NSScreen {
    /// A stable identifier for the physical display. NSScreen objects themselves can
    /// be replaced when the display configuration changes.
    var displayNumber: NSNumber? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
}
