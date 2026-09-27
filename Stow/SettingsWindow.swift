import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window: an ordinary AppKit window with a SwiftUI form inside.
///
/// SwiftUI's own `Settings` scene is awkward to open from a menu-bar-only app, so
/// Stow makes the window itself and hosts the SwiftUI view in it.
final class SettingsWindowController {
    private let settings: AppSettings
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        settings.refreshLoginItemStatus()
        // Stow is never the active app, so bring it forward for the window, like
        // clicking a normal app's Dock icon would.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        // NSHostingController sizes the window to fit the SwiftUI view.
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
        window.title = "Stow Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Open Stow when you log in", isOn: $settings.launchAtLogin)
                if settings.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Waiting for your approval in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
                if let error = settings.loginItemError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Toggle("Show the number of items in the menu bar", isOn: $settings.showCountInMenuBar)
            } header: {
                Text("General")
            } footer: {
                Text("Open at login works best once Stow is in your Applications folder.")
            }

            Section {
                LabeledContent("Show or hide the shelf") {
                    HStack {
                        if settings.shortcut != KeyCombo.default, !settings.isRecordingShortcut {
                            Button("Use ⌃⌥S") {
                                settings.shortcut = KeyCombo.default
                            }
                            .buttonStyle(.link)
                        }
                        ShortcutRecorder(shortcut: settings.shortcut, settings: settings)
                            .frame(minWidth: 110)
                            .fixedSize()
                    }
                }
                if let problem = settings.shortcutProblem {
                    Text(problem)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Click the shortcut, then press the keys you want. Delete turns it off. On the shelf, use the arrow keys, Space to preview, Return to open, ⌘C to copy, and type a name to filter.")
            }

            Section {
                Toggle("Remove items after dragging them out", isOn: $settings.removeAfterDrag)
                Toggle("Stack files dropped together", isOn: $settings.stackDroppedFiles)
                Stepper(value: $settings.visibleItemLimit, in: AppSettings.visibleItemRange) {
                    LabeledContent("Items shown before scrolling", value: "\(settings.visibleItemLimit)")
                }
                Picker("Dock to", selection: $settings.dockEdge) {
                    Text("Side nearest the pointer").tag(DockEdgePreference.nearest)
                    Text("Left side").tag(DockEdgePreference.left)
                    Text("Right side").tag(DockEdgePreference.right)
                }
                Toggle("Only show when a drag reaches the side of the screen", isOn: $settings.showOnlyAtScreenEdge)
            } header: {
                Text("Shelf")
            } footer: {
                Text("Drag the shelf by an empty spot to put it anywhere. Reset Shelf Position in the menu bar docks it again. Drag an item away from the shelf and let go where nothing takes it to remove it.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
