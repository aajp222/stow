import AppKit

/// The floating window that holds the shelf.
final class ShelfPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: ShelfLayout.width, height: ShelfLayout.emptyHeight),
            // .borderless: no title bar or frame; the shelf draws its own rounded
            // background.
            // .nonactivatingPanel: clicking the panel does NOT make Stow the active
            // app, so the app you're working in stays frontmost and keeps its menu bar
            // and focused window. Only NSPanel supports this style.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Float above normal app windows, like a tool palette.
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,     // on every Space instead of belonging to one
            .fullScreenAuxiliary,  // allowed to appear over an app in full screen
            .ignoresCycle,         // skipped when cycling windows with ⌘`
        ]

        // Panels normally hide when their app stops being active. Stow is almost
        // never the active app, so that would hide the shelf constantly.
        hidesOnDeactivate = false

        // A transparent window: the rounded background view is all you see, and the
        // window shadow follows its shape.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        isMovable = false
        isReleasedWhenClosed = false
        // ShelfPanelController runs its own slide animation.
        animationBehavior = .none
    }

    // There's no title bar to drag, so the shelf moves itself: ShelfContentView and
    // ShelfCollectionView call followMouseDrag() (below) when you press on an empty
    // part of the shelf. `isMovable = false` only stops the window server from
    // moving the window on its own; moving it from code still works.

    // A borderless window can't become the key window, and that's deliberate:
    // becoming key would take keyboard focus from the app you're typing in. Phase 4's
    // spacebar Quick Look will revisit this.
}

extension NSWindow {
    /// Moves the window along with the mouse until the button is released. Call it
    /// from `mouseDown`. It's a classic AppKit tracking loop: it takes the drag events
    /// straight off the event queue until the mouse-up arrives.
    ///
    /// Returns false if the mouse barely moved, meaning it was a click, not a drag.
    func followMouseDrag() -> Bool {
        let start = NSEvent.mouseLocation
        let origin = frame.origin
        var moved = false
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.x
            let dy = mouse.y - start.y
            // Ignore a few points of wobble so a plain click never nudges the shelf.
            if !moved, abs(dx) < 3, abs(dy) < 3 { continue }
            moved = true
            setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        }
        return moved
    }
}
