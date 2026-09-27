import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window: an ordinary AppKit window with a SwiftUI form inside.
///
/// SwiftUI's own `Settings` scene is awkward to open from a menu-bar-only app, so
/// Stow makes the window itself and hosts the SwiftUI view in it.
final class SettingsWindowController {
    private let settings: AppSettings
    private let updateChecker: UpdateChecker
    private var window: NSWindow?

    init(settings: AppSettings, updateChecker: UpdateChecker) {
        self.settings = settings
        self.updateChecker = updateChecker
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
        let view = SettingsView(settings: settings) { [updateChecker] in
            Task {
                await updateChecker.check(userInitiated: true)
            }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Stow Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    /// The About section's Check Now button.
    let checkForUpdates: () -> Void

    /// The version from the app's Info.plist, such as "1.2 (1)".
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

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
                Toggle("Stack files stowed together", isOn: $settings.stackDroppedFiles)
                Stepper(value: $settings.visibleItemLimit, in: AppSettings.visibleItemRange) {
                    LabeledContent("Items shown before scrolling", value: "\(settings.visibleItemLimit)")
                }
                Picker("Dock to", selection: $settings.dockEdge) {
                    Text("Side nearest the pointer").tag(DockEdgePreference.nearest)
                    Text("Left side").tag(DockEdgePreference.left)
                    Text("Right side").tag(DockEdgePreference.right)
                }
                Picker("Show the shelf", selection: $settings.shelfTrigger) {
                    Text("As soon as you drag something").tag(ShelfTrigger.anyDrag)
                    Text("When a drag reaches the side of the screen").tag(ShelfTrigger.screenEdge)
                    Text("When you shake the pointer while dragging").tag(ShelfTrigger.shake)
                }
            } header: {
                Text("Shelf")
            } footer: {
                Text("Drag the shelf by an empty spot to put it anywhere. Reset Shelf Position in the menu bar docks it again. Drag an item away from the shelf and let go where nothing takes it to remove it.")
            }

            Section {
                Toggle("Add new screenshots to the shelf", isOn: screenshotsBinding)
                if settings.stowScreenshots {
                    LabeledContent("Screenshots folder") {
                        HStack {
                            Text(screenshotFolderName ?? "Not chosen")
                                .foregroundStyle(.secondary)
                            Button("Change…") {
                                chooseScreenshotFolder()
                            }
                        }
                    }
                }
            } header: {
                Text("Screenshots")
            } footer: {
                Text("Stow watches the folder your screenshots are saved in: your Desktop, unless you changed it in the Screenshot app (⇧⌘5 → Options).")
            }

            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stow")
                            .font(.headline)
                        Text("Version \(Self.version)")
                            .foregroundStyle(.secondary)
                        Text("Made by Aaryan Panchal")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                // Copies from the App Store are updated by the App Store.
                if !UpdateChecker.isAppStoreCopy {
                    HStack {
                        Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
                        Spacer()
                        Button("Check Now", action: checkForUpdates)
                    }
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        // The form scrolls if the screen is too short for all of it.
        .frame(width: 460, height: 640)
    }

    // MARK: - Screenshots folder

    /// Turning screenshots on for the first time asks for the folder; cancelling
    /// leaves it off.
    private var screenshotsBinding: Binding<Bool> {
        Binding {
            settings.stowScreenshots
        } set: { isOn in
            if isOn, settings.screenshotFolderBookmark == nil, !chooseScreenshotFolder() {
                return
            }
            settings.stowScreenshots = isOn
        }
    }

    private var screenshotFolderName: String? {
        settings.screenshotFolderBookmark.flatMap { ScreenshotWatcher.resolve($0) }?.lastPathComponent
    }

    /// The sandbox only lets Stow watch a folder you pick yourself, so this asks, in
    /// an Open panel that starts at your Desktop.
    @discardableResult
    private func chooseScreenshotFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder your screenshots are saved in. Unless you've changed it, that's your Desktop."
        panel.directoryURL = ScreenshotWatcher.realHomeFolder.appending(path: "Desktop", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let folder = panel.url, let bookmark = ScreenshotWatcher.bookmark(for: folder) else {
            return false
        }
        settings.screenshotFolderBookmark = bookmark
        return true
    }
}
