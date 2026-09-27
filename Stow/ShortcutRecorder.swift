import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The Settings control for the show/hide shortcut: click it, then press the keys
/// you want. Esc cancels, and Delete turns the shortcut off.
struct ShortcutRecorder: NSViewRepresentable {
    /// Passed in (rather than read from `settings` here) so SwiftUI updates the
    /// control whenever the shortcut changes.
    let shortcut: KeyCombo?
    let settings: AppSettings

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.settings = settings
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
    }
}

/// An AppKit button that records the next key combination pressed while it's the
/// window's first responder. SwiftUI has no way to capture a raw key combination
/// such as ⌃⌥S, so this part is AppKit.
final class ShortcutRecorderButton: NSButton {
    var settings: AppSettings?
    var shortcut: KeyCombo? {
        didSet { updateTitle() }
    }

    private var isRecording = false {
        didSet {
            // AppDelegate switches the current shortcut off while this is set, so
            // pressing it gets recorded instead of toggling the shelf.
            settings?.isRecordingShortcut = isRecording
            updateTitle()
        }
    }
    private var resignKeyObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        setAccessibilityHelp("Click, then press the new shortcut. Press Delete to turn it off.")
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    private func updateTitle() {
        title = isRecording ? "Press keys…" : (shortcut?.display ?? "None")
    }

    @objc private func clicked() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let window, window.makeFirstResponder(self) else { return }
        isRecording = true
        // Stop if you switch to another window or close Settings mid-recording.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopRecording()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Combinations with ⌘ arrive as key equivalents before they'd reach keyDown, so
    /// catch them here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, keyCode == kVK_Escape {
            stopRecording()
            return
        }
        if modifiers.isEmpty, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            settings?.shortcut = nil
            stopRecording()
            return
        }
        // A plain letter would be swallowed everywhere you type it, so ask for at
        // least one of ⌘, ⌃ or ⌥ (a function key on its own is fine).
        let isFunctionKey = Self.functionKeyNames[keyCode] != nil
        guard isFunctionKey || !modifiers.isDisjoint(with: [.command, .control, .option]) else {
            NSSound.beep()
            return
        }
        settings?.shortcut = KeyCombo(
            keyCode: keyCode,
            modifiers: Self.carbonModifiers(modifiers),
            display: Self.symbols(for: modifiers) + Self.keyName(for: event)
        )
        stopRecording()
    }

    // MARK: - Describing keys

    /// The modifier flags Carbon's RegisterEventHotKey expects.
    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    /// Modifier symbols in the order macOS menus show them.
    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// The key's name: its letter or symbol without Shift or Option applied (so ⌥S
    /// reads "S", not "ß"), or a name for keys that don't type anything.
    private static func keyName(for event: NSEvent) -> String {
        let keyCode = Int(event.keyCode)
        if let name = functionKeyNames[keyCode] ?? specialKeyNames[keyCode] {
            return name
        }
        let character = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        return character.isEmpty ? "Key \(keyCode)" : character.uppercased()
    }
}
