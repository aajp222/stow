import AppKit

/// Notices when you pick something up in any app (files, photos, text, a link) so
/// the shelf can slide in, and when you let go of it.
///
/// Permissions: none. Watching *mouse* events in other apps with a global monitor
/// doesn't need Accessibility access; only watching the keyboard would. Global
/// monitors can only observe events, never change or block them.
final class DragMonitor {
    /// A drag the shelf can accept is under way. The point is the mouse location in
    /// screen coordinates.
    var onDragBegan: (NSPoint) -> Void = { _ in }
    /// That drag ended: the mouse button was released, over the shelf or anywhere else.
    var onDragEnded: () -> Void = {}
    /// What has to happen before a drag is announced (the "Show the shelf" setting):
    /// nothing more, the pointer reaching the side of a screen, or a shake.
    var trigger: () -> ShelfTrigger = { .anyDrag }

    /// How close to the side of the screen counts as "reaching" it.
    private let edgeDistance: CGFloat = 40

    /// The system-wide pasteboard an app writes to when it starts a drag-and-drop.
    private let dragPasteboard = NSPasteboard(name: .drag)

    /// The drag pasteboard's `changeCount` the last time the mouse button was
    /// released. The count goes up every time an app puts something on the drag
    /// pasteboard, so if it has moved while the button is held, a real drag-and-drop
    /// has started. Moving a window, selecting text, or rubber-band selecting holds
    /// the button without touching the pasteboard, so those never trigger the shelf.
    ///
    /// (Comparing with the count at mouse-*up* rather than mouse-down means an app
    /// that fills the pasteboard the instant the button goes down still counts.)
    private var idleChangeCount: Int
    /// The mouse went down in one of Stow's own windows, so any drag is Stow's own
    /// (items being dragged out, or the shelf being moved) and must not trigger it.
    private var mouseDownInStow = false
    /// A drag the shelf can accept has been spotted during this press...
    private var isTrackingDrag = false
    /// ...and `onDragBegan` has been called for it.
    private var hasAnnouncedDrag = false

    private var monitors: [Any] = []
    /// Runs while the button is held; see `watchPress()`.
    private var pressTimer: Timer?
    private var shakeDetector = ShakeDetector()

    init() {
        idleChangeCount = dragPasteboard.changeCount
    }

    func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

        // Global monitor: sees mouse events sent to every *other* app.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            // AppKit calls monitor handlers on the main thread.
            MainActor.assumeIsolated { self?.handle(event, inStow: false) }
        }) {
            monitors.append(monitor)
        }

        // Local monitor: sees events sent to Stow itself, which the global monitor
        // never does. It must return the event so it's still delivered normally.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, inStow: true) }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func handle(_ event: NSEvent, inStow: Bool) {
        switch event.type {
        case .leftMouseDown:
            mouseDownInStow = inStow
            watchPress()
        case .leftMouseDragged:
            // Normally already running since the mouse-down; this covers a missed one.
            watchPress()
        case .leftMouseUp:
            buttonReleased()
        default:
            break
        }
    }

    /// While the button is held, check sixty times a second whether a drag has
    /// started, whether it has reached the side of the screen or been shaken (if the
    /// setting asks for that), and whether the button is still down. (Sixty, so a
    /// quick shake doesn't slip between two looks at the pointer.)
    ///
    /// Mouse-dragged events alone aren't enough. Once another app's drag gets going,
    /// its events don't always reach our monitors, and the final mouse-up can be
    /// swallowed too. Polling catches both, so no drag slips through.
    private func watchPress() {
        guard pressTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Bit 0 of pressedMouseButtons is the left (primary) button.
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self?.buttonReleased()
                } else {
                    self?.inspectDrag()
                }
            }
        }
        // .common keeps the timer firing while menus or other tracking loops run.
        RunLoop.main.add(timer, forMode: .common)
        pressTimer = timer
    }

    private func inspectDrag() {
        guard !hasAnnouncedDrag, !mouseDownInStow else { return }

        if !isTrackingDrag {
            guard dragPasteboard.changeCount != idleChangeCount else { return }
            // Only drags the shelf can take: files, promises, links, text, images.
            // This checks the pasteboard's types only: reading another app's drag
            // data here would be blocked by macOS's pasteboard privacy (see
            // PasteboardContents.offersAcceptedTypes). It runs again on every tick,
            // because an app empties the pasteboard (which bumps the count) a moment
            // before it adds the types.
            guard PasteboardContents.offersAcceptedTypes(dragPasteboard) else { return }
            isTrackingDrag = true
        }

        let point = NSEvent.mouseLocation
        switch trigger() {
        case .anyDrag:
            break
        case .screenEdge:
            guard isNearSideOfScreen(point) else { return }
        case .shake:
            guard shakeDetector.add(point, at: ProcessInfo.processInfo.systemUptime) else { return }
        }
        hasAnnouncedDrag = true
        onDragBegan(point)
    }

    private func isNearSideOfScreen(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        return point.x - screen.frame.minX < edgeDistance || screen.frame.maxX - point.x < edgeDistance
    }

    private func buttonReleased() {
        pressTimer?.invalidate()
        pressTimer = nil
        if hasAnnouncedDrag {
            onDragEnded()
        }
        isTrackingDrag = false
        hasAnnouncedDrag = false
        idleChangeCount = dragPasteboard.changeCount
        mouseDownInStow = false
        shakeDetector.reset()
    }
}

/// Spots a shake: the pointer swinging left and right several times in quick
/// succession, like shaking something loose.
struct ShakeDetector {
    /// How far a swing must travel to count, in points.
    var minimumSwing: CGFloat = 25
    /// How many changes of direction make a shake...
    var requiredTurns = 3
    /// ...and within how many seconds.
    var timeWindow: TimeInterval = 1.0

    private var lastX: CGFloat?
    /// -1 moving left, 1 moving right, 0 not yet known.
    private var direction: CGFloat = 0
    /// Where the current swing started.
    private var swingStartX: CGFloat = 0
    /// When each recent change of direction happened.
    private var turns: [TimeInterval] = []

    mutating func reset() {
        lastX = nil
        direction = 0
        turns = []
    }

    /// Adds a pointer position (screen coordinates) seen at `time` (seconds, any
    /// steady clock). Returns true once the recent movement is a shake.
    mutating func add(_ point: NSPoint, at time: TimeInterval) -> Bool {
        guard let previousX = lastX else {
            lastX = point.x
            swingStartX = point.x
            return false
        }
        lastX = point.x
        let dx = point.x - previousX
        guard abs(dx) >= 1 else { return false }
        let newDirection: CGFloat = dx > 0 ? 1 : -1
        if newDirection != direction {
            // The swing that just ended ran from swingStartX to previousX.
            if direction != 0, abs(previousX - swingStartX) >= minimumSwing {
                turns.append(time)
            }
            direction = newDirection
            swingStartX = previousX
        }
        turns.removeAll { time - $0 > timeWindow }
        return turns.count >= requiredTurns
    }
}
