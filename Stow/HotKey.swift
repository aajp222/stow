import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut, registered with Carbon's `RegisterEventHotKey`.
///
/// Carbon is AppKit's much older sibling, but this one API is still how Mac apps
/// register global shortcuts. It needs no permission: macOS delivers only this
/// exact key combination to Stow and swallows it, so the key isn't also typed into
/// the app you're in. (Watching *all* keystrokes with an NSEvent global monitor
/// would need Accessibility access and couldn't stop the key being typed.)
final class HotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// `action` runs whenever the registered shortcut is pressed. Nothing is
    /// registered until `register(_:)` is called.
    init(action: @escaping () -> Void) {
        self.action = action

        // Ask Carbon to call hotKeyPressed (below) for hot-key events sent to Stow,
        // passing a pointer to this object so the C callback can find it again.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        if InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &eventType, context, &handlerRef) != noErr {
            NSLog("Stow: couldn't listen for the keyboard shortcut.")
        }
    }

    /// Registers `combo` in place of the current shortcut, or just removes the current
    /// one when `combo` is nil. Returns false if it couldn't be registered, for example
    /// because another app already uses that combination.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        guard let combo else { return true }
        guard handlerRef != nil else { return false }
        // 'STOW' as a four-character code, identifying our shortcut.
        let id = EventHotKeyID(signature: 0x5354_4F57, id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    fileprivate func fire() {
        action()
    }
}

/// The C callback Carbon calls when the shortcut is pressed. It must be a plain
/// function (no captured state), so the HotKey object comes back through `userData`.
/// `nonisolated` because C calls it directly; Carbon calls it on the main thread.
private nonisolated func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        hotKey.fire()
    }
    return noErr
}
