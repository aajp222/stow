import AppKit
import SwiftUI

/// The welcome card: three steps that explain Stow. It opens by itself the first
/// time Stow runs, and again from the menu bar's "How to Use Stow".
final class WelcomeWindowController {
    private let settings: AppSettings
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        settings.hasSeenWelcome = true
        settings.refreshLoginItemStatus()
        // Like the Settings window: bring Stow forward so the card comes to the front.
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = WelcomeView(settings: settings) { [weak self] in
            self?.window?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Stow"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        return window
    }
}

struct WelcomeView: View {
    @Bindable var settings: AppSettings
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Welcome to Stow")
                    .font(.title.bold())
                Text("A shelf for everything you're dragging around.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                step(
                    symbol: "hand.draw",
                    title: "Pick something up",
                    text: "Start dragging a file, photo, some text or a link in any app. The shelf slides in."
                )
                step(
                    symbol: "tray.and.arrow.down",
                    title: "Stow it",
                    text: "Drop it on the shelf and carry on. It waits there, even after a restart."
                )
                step(
                    symbol: "arrow.up.forward.app",
                    title: "Drag it out",
                    text: "When you're ready, drag it wherever it needs to go.\(shortcutHint)"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Stow lives in the menu bar, under the tray icon. Its settings are there too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Toggle("Open Stow when you log in", isOn: $settings.launchAtLogin)
                Button("Get Started", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shortcutHint: String {
        settings.shortcut.map { " Press \($0.display) to show or hide the shelf any time." } ?? ""
    }

    private func step(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
