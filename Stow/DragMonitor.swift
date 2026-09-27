import AppKit

/// Notices when you pick up files in any app (so the shelf can slide in) and when
/// you let go of them.
///
/// Permissions: none. Watching *mouse* events in other apps with a global monitor
/// doesn't need Accessibility access; only watching the keyboard would. Global
/// monitors can only observe events, never change or block them.
final class DragMonitor {
    /// A drag carrying files or file promises just started. The point is the mouse
    /// location in screen coordinates.
    var onFileDragBegan: (NSPoint) -> Void = { _ in }
    /// That drag ended: the mouse button was released, over the shelf or anywhere else.
    var onFileDragEnded: () -> Void = {}

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
    private var isTrackingFileDrag = false

    private var monitors: [Any] = []
    /// Runs while the button is held; see `watchPress()`.
    private var pressTimer: Timer?

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

    /// While the button is held, check twenty times a second whether a drag has
    /// started and whether the button is still down.
    ///
    /// Mouse-dragged events alone aren't enough. Once another app's drag gets going,
    /// its events don't always reach our monitors, and the final mouse-up can be
    /// swallowed too. Polling catches both, so no drag slips through.
    private func watchPress() {
        guard pressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
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
        guard !isTrackingFileDrag, !mouseDownInStow,
              dragPasteboard.changeCount != idleChangeCount
        else { return }

        // Only drags carrying files, folders or file promises. Dragged text also lands
        // on the drag pasteboard, but the shelf can't hold text until Phase 4.
        //
        // This checks the pasteboard's types only: reading another app's drag data
        // here would be blocked by macOS's pasteboard privacy (see offersFileTypes).
        // It runs again on every tick, because an app empties the pasteboard (which
        // bumps the count) a moment before it adds the file types.
        guard ShelfDropView.offersFileTypes(dragPasteboard) else { return }

        isTrackingFileDrag = true
        onFileDragBegan(NSEvent.mouseLocation)
    }

    private func buttonReleased() {
        pressTimer?.invalidate()
        pressTimer = nil
        if isTrackingFileDrag {
            isTrackingFileDrag = false
            onFileDragEnded()
        }
        idleChangeCount = dragPasteboard.changeCount
        mouseDownInStow = false
    }
}
