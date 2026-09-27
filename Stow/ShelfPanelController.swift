import AppKit
import Observation
import QuartzCore

/// Which side of the screen the shelf docks to when it places itself. The shelf is a
/// tall, narrow strip, so only the left and right edges make sense.
enum ShelfEdge {
    case left, right
}

/// Where the shelf appears.
enum ShelfPlacement: Equatable {
    /// Docked to the left or right edge, whichever is nearer the pointer, and
    /// vertically centred.
    case automatic
    /// Wherever you last dragged it. Stored relative to the display's usable area so
    /// it lands in the same spot on any display: `x` runs from 0 (left) to 1 (right),
    /// `top` from 0 (top of the screen) to 1 (bottom).
    case custom(x: CGFloat, top: CGFloat)
}

/// Shows, hides, positions and animates the shelf panel.
final class ShelfPanelController {
    let viewModel: ShelfViewModel
    private let settings: AppSettings

    private let viewController: ShelfViewController
    private let panel = ShelfPanel()

    private(set) var isShown = false
    private var screen: NSScreen?
    /// The edge used by automatic placement: the one nearest the pointer when the
    /// last drag started.
    private var edge: ShelfEdge = .right
    private var placement: ShelfPlacement {
        didSet { Self.savePlacement(placement) }
    }
    /// Bumped on every show and hide, so a hide animation that finishes late doesn't
    /// remove a panel that was shown again in the meantime.
    private var animationGeneration = 0
    /// Bumped for every drag, so a hide check scheduled at the end of one drag can
    /// tell that another drag has started since.
    private var dragGeneration = 0
    private var screenObserver: NSObjectProtocol?

    /// How far the shelf slides while it fades in or out.
    private let slideDistance: CGFloat = 24

    init(viewModel: ShelfViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
        placement = Self.loadPlacement()
        viewController = ShelfViewController(viewModel: viewModel)
        viewController.onHide = { [weak self] in self?.hide() }
        viewController.onContentChanged = { [weak self] in self?.contentChanged() }
        viewController.onDragOutEnded = { [weak self] in self?.dragEnded() }
        viewController.onMoved = { [weak self] in self?.userMovedShelf() }
        panel.contentView = viewController.view

        // Displays plugged in, unplugged or rearranged: re-place the shelf so it isn't
        // left off-screen or in an odd spot.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        observeSettings()
    }

    /// Re-lays out the shelf when "Items shown before scrolling" or "Dock to" changes
    /// in Settings, the same observation pattern ShelfViewController uses for items.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.visibleItemLimit
            _ = settings.dockEdge
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.edge = self.dockingEdge(nearestTo: nil, on: nil)
                self.contentChanged()
                self.observeSettings()
            }
        }
    }

    // MARK: - Showing and hiding

    /// The menu bar's Show/Hide Shelf command.
    func toggle() {
        if isShown {
            hide()
        } else {
            edge = dockingEdge(nearestTo: nil, on: nil)
            show(on: Self.screenWithMouse())
        }
    }

    /// Slides the shelf in on `screen`, at its placement. If it's already there, just
    /// makes sure it's the right size.
    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let target = targetFrame(on: screen)
        if isShown, self.screen?.displayNumber == screen.displayNumber, abs(panel.frame.minX - target.minX) < 1 {
            animate(to: target)
            return
        }

        self.screen = screen
        isShown = true
        animationGeneration += 1

        // Start a little further toward the nearer side and fully transparent, then
        // slide in.
        let outward = Self.outwardDirection(of: target, on: screen)
        panel.setFrame(target.offsetBy(dx: outward * slideDistance, dy: 0), display: false)
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
        let outward = Self.outwardDirection(of: panel.frame, on: screen)
        let target = panel.frame.offsetBy(dx: outward * slideDistance, dy: 0)
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

    /// A drag started somewhere on the Mac. Bring the shelf to the display the pointer
    /// is on. If it's already there, it stays put.
    func dragBegan(at point: NSPoint) {
        dragGeneration += 1
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        edge = dockingEdge(nearestTo: point, on: screen)
        show(on: screen)
    }

    /// The side automatic placement docks to: the side chosen in Settings, or else the
    /// side nearer `point` (the pointer), or else the side it used last time.
    private func dockingEdge(nearestTo point: NSPoint?, on screen: NSScreen?) -> ShelfEdge {
        switch settings.dockEdge {
        case .left:
            return .left
        case .right:
            return .right
        case .nearest:
            guard let point, let screen else { return edge }
            return point.x < screen.visibleFrame.midX ? .left : .right
        }
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

    // MARK: - Placement

    /// Whether the shelf has been dragged to a spot of its own (so the menu's Reset
    /// Shelf Position has something to do).
    var hasCustomPlacement: Bool { placement != .automatic }

    /// The user dragged the shelf somewhere. Keep it fully on screen and remember the
    /// spot for next time.
    private func userMovedShelf() {
        guard let screen = panel.screen ?? Self.screenWithMouse() else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true, animate: true)
        }

        self.screen = screen
        let spareWidth = visible.width - frame.width
        placement = .custom(
            x: spareWidth > 0 ? (frame.minX - visible.minX) / spareWidth : 0,
            top: (visible.maxY - frame.maxY) / visible.height
        )
    }

    /// The menu's Reset Shelf Position command: go back to docking at the screen edge.
    func resetPlacement() {
        if isShown, let screen {
            edge = dockingEdge(nearestTo: NSPoint(x: panel.frame.midX, y: panel.frame.midY), on: screen)
        }
        placement = .automatic
        if isShown, let screen {
            animate(to: targetFrame(on: screen))
        }
    }

    /// Where the shelf sits on `screen`: as tall as its items need, up to 70% of the
    /// screen (the list scrolls past that).
    private func targetFrame(on screen: NSScreen) -> NSRect {
        // visibleFrame leaves out the menu bar and the Dock, so the shelf never
        // tucks underneath either of them.
        let visible = screen.visibleFrame
        let width = ShelfLayout.width
        // Grow to fit at most `visibleItemLimit` items; the list scrolls past that.
        let shownItems = min(viewModel.items.count, settings.visibleItemLimit)
        let height = min(ShelfLayout.contentHeight(itemCount: shownItems), visible.height * 0.7).rounded()

        switch placement {
        case .automatic:
            let x = switch edge {
            case .left: visible.minX + ShelfLayout.screenMargin
            case .right: visible.maxX - width - ShelfLayout.screenMargin
            }
            return NSRect(x: x, y: (visible.midY - height / 2).rounded(), width: width, height: height)

        case .custom(let xFraction, let topFraction):
            // The top edge stays where you put it and the shelf grows downward. If
            // that would run off the bottom of the screen, it's pushed up instead.
            let x = visible.minX + xFraction * max(visible.width - width, 0)
            let top = visible.maxY - topFraction * visible.height
            let y = max(top - height, visible.minY)
            return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
        }
    }

    private func contentChanged() {
        guard isShown, let screen else { return }
        animate(to: targetFrame(on: screen))
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
        panel.setFrame(targetFrame(on: newScreen), display: true)
    }

    /// The direction the shelf slides out: -1 when it's nearer the screen's left
    /// side, +1 when nearer the right.
    private static func outwardDirection(of frame: NSRect, on screen: NSScreen?) -> CGFloat {
        guard let screen else { return 1 }
        return frame.midX < screen.visibleFrame.midX ? -1 : 1
    }

    /// The display the mouse pointer is on.
    static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - Saving the placement

    private static let placementXKey = "ShelfPlacementX"
    private static let placementTopKey = "ShelfPlacementTop"

    private static func loadPlacement() -> ShelfPlacement {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: placementXKey) != nil, defaults.object(forKey: placementTopKey) != nil else {
            return .automatic
        }
        return .custom(
            x: CGFloat(defaults.double(forKey: placementXKey)),
            top: CGFloat(defaults.double(forKey: placementTopKey))
        )
    }

    private static func savePlacement(_ placement: ShelfPlacement) {
        let defaults = UserDefaults.standard
        switch placement {
        case .automatic:
            defaults.removeObject(forKey: placementXKey)
            defaults.removeObject(forKey: placementTopKey)
        case .custom(let x, let top):
            defaults.set(Double(x), forKey: placementXKey)
            defaults.set(Double(top), forKey: placementTopKey)
        }
    }
}

private extension NSScreen {
    /// A stable identifier for the physical display. NSScreen objects themselves can
    /// be replaced when the display configuration changes.
    var displayNumber: NSNumber? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
}
