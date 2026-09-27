import AppKit

/// Alerts and Open panels, shown the way a menu bar app has to.
enum Dialog {
    /// Runs a dialog. Stow is normally never the active app, but you can only type
    /// into a dialog in the active app, so activate Stow for the dialog, then give
    /// activation back to the app you were using.
    static func run<Result>(_ body: () -> Result) -> Result {
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        let result = body()
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(from: .current, options: [])
        }
        return result
    }

    static func showProblem(_ title: String, details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        _ = run { alert.runModal() }
    }
}
