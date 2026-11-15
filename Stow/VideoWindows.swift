import AppKit
import AVKit

/// The Trim Video window: the video with QuickTime Player's yellow trim bar under
/// it. Drag the ends, click Trim, and `onTrim` gets the part you kept.
final class TrimWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let playerView = AVPlayerView()
    private let player: AVPlayer
    private var statusObservation: NSKeyValueObservation?
    private var onTrim: ((CMTimeRange) -> Void)?
    private var onClose: (() -> Void)?

    /// `onTrim` is called if you click Trim; `onClose` once the window has gone,
    /// either way.
    init(url: URL, onTrim: @escaping (CMTimeRange) -> Void, onClose: @escaping () -> Void) {
        player = AVPlayer(url: url)
        self.onTrim = onTrim
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Trim “\(url.lastPathComponent)”"
        window.isReleasedWhenClosed = false
        window.delegate = self
        playerView.player = player
        playerView.controlsStyle = .inline
        window.contentView = playerView
    }

    func show() {
        // Like the Settings window: bring Stow forward so the window comes to the front.
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        // The trim bar can only come up once the video has loaded.
        statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in self?.itemStatusChanged(status) }
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            statusObservation = nil
            guard playerView.canBeginTrimming else {
                fail("This video can't be trimmed.")
                return
            }
            playerView.beginTrimming { [weak self] result in
                Task { @MainActor [weak self] in self?.trimmingEnded(result) }
            }
        case .failed:
            statusObservation = nil
            fail(player.currentItem?.error?.localizedDescription ?? "The video couldn't be opened.")
        default:
            break
        }
    }

    private func trimmingEnded(_ result: AVPlayerViewTrimResult) {
        if result == .okButton, let item = player.currentItem {
            // The trim bar records your choice as the item's playback limits.
            let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration
            if end > start {
                onTrim?(CMTimeRange(start: start, end: end))
            }
        }
        window.close()
    }

    private func fail(_ details: String) {
        window.close()
        Dialog.showProblem("Couldn't trim the video", details: details)
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        statusObservation = nil
        onTrim = nil
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
    }
}

/// A small floating window with a progress bar and a Cancel button, shown while a
/// video is being converted or trimmed (which can take minutes).
final class VideoProgressPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var onCancel: () -> Void = {}

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 84),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Stow"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        label.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.controlSize = .small
        let row = NSStackView(views: [bar, cancel])
        row.spacing = 10
        let stack = NSStackView(views: [label, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32).isActive = true
        panel.contentView = stack
    }

    func show(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel.center()
        panel.orderFrontRegardless()
    }

    func update(_ text: String, progress: Double) {
        label.stringValue = text
        bar.doubleValue = progress
    }

    func close() {
        panel.close()
    }

    @objc private func cancelClicked() {
        onCancel()
    }
}
