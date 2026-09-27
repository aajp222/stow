import AppKit

/// Notices when you start dragging files anywhere on the Mac (so the shelf can slide
/// in) and when that drag ends.
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

    /// The drag pasteboard's `changeCount` when the mouse button went down. The count
    /// goes up every time an app puts something on the drag pasteboard, so if it has
    /// moved by the time the mouse is dragged, a real drag-and-drop has started.
    /// Moving a window, selecting text, or rubber-band selecting drags the mouse
    /// without touching the pasteboard, so those never trigger the shelf.
    private var changeCountAtMouseDown: Int
    /// Each drag is inspected once, on the first mouse-dragged event after the count moves.
    private var inspectedThisDrag = false
    /// The mouse went down in one of Stow's own windows, so any drag is Stow's own
    /// (items being dragged out of the shelf) and must not move the shelf around.
    private var mouseDownInStow = false
    private var isTrackingFileDrag = false

    private var monitors: [Any] = []
    private var releaseTimer: Timer?

    /// Pasteboard types that mean "files": the same types the shelf accepts.
    private static let fileTypes = Set(ShelfDropView.acceptedTypes)

    init() {
        changeCountAtMouseDown = dragPasteboard.changeCount
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
            resetForNextDrag()
            mouseDownInStow = inStow
        case .leftMouseDragged:
            inspectDrag()
        case .leftMouseUp:
            fileDragFinished()
            resetForNextDrag()
        default:
            break
        }
    }

    private func resetForNextDrag() {
        changeCountAtMouseDown = dragPasteboard.changeCount
        inspectedThisDrag = false
        mouseDownInStow = false
    }

    private func inspectDrag() {
        guard !inspectedThisDrag, dragPasteboard.changeCount != changeCountAtMouseDown else { return }
        inspectedThisDrag = true

        // Only files and file promises for now. Dragged text also lands on the drag
        // pasteboard, but the shelf can't hold text until Phase 4.
        guard !mouseDownInStow,
              let types = dragPasteboard.types,
              !Self.fileTypes.isDisjoint(with: types)
        else { return }

        isTrackingFileDrag = true
        watchForRelease()
        onFileDragBegan(NSEvent.mouseLocation)
    }

    /// Some apps run their own event loop during a drag, and the final mouse-up doesn't
    /// always reach our monitors. So while a file drag is going, also check the mouse
    /// button's state ten times a second.
    private func watchForRelease() {
        releaseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Bit 0 of pressedMouseButtons is the left (primary) button.
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self?.fileDragFinished()
                    self?.resetForNextDrag()
                }
            }
        }
        // .common keeps the timer firing while menus or other tracking loops run.
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    private func fileDragFinished() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        guard isTrackingFileDrag else { return }
        isTrackingFileDrag = false
        onFileDragEnded()
    }
}
