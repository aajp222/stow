import Carbon.HIToolbox

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

    /// `keyCode` is a virtual key code such as `kVK_ANSI_S`; `modifiers` are Carbon
    /// flags such as `controlKey | optionKey`. Returns nil if the shortcut couldn't be
    /// registered, for example because another app already uses it.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        // Ask Carbon to call hotKeyPressed (below) for hot-key events sent to Stow,
        // passing a pointer to this object so the C callback can find it again.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &eventType, context, &handlerRef) == noErr else {
            return nil
        }

        // 'STOW' as a four-character code, identifying our shortcut.
        let id = EventHotKeyID(signature: 0x5354_4F57, id: 1)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            RemoveEventHandler(handlerRef)
            return nil
        }
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
