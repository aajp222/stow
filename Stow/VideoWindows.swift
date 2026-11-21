import AppKit
import AVKit
import SwiftUI

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
    init(url: URL, title: String? = nil, onTrim: @escaping (CMTimeRange) -> Void, onClose: @escaping () -> Void) {
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
        window.title = title ?? "Trim “\(url.lastPathComponent)”"
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

/// The floating progress window for video and audio jobs, which can take minutes:
/// a small Liquid Glass card like the shelf, near the top of the screen. It never
/// takes focus, and you can drag it out of the way. VideoProgressView draws it.
final class VideoProgressPanel {
    private let panel: NSPanel
    private let model = VideoProgressModel()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: VideoProgressView.width, height: 86),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        let hosting = FirstClickHostingView(rootView: VideoProgressView(model: model))
        let glass = NSGlassEffectView()
        glass.cornerRadius = 24
        glass.contentView = hosting
        panel.contentView = glass
        panel.setContentSize(hosting.fittingSize)
    }

    func show(onCancel: @escaping () -> Void) {
        model.onCancel = onCancel
        model.startedAt = Date()
        // Top centre of the screen you're on, clear of the menu bar.
        let screen = ShelfPanelController.screenWithMouse() ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.maxY - panel.frame.height - 24
            ))
        }
        panel.orderFrontRegardless()
    }

    /// Moves on to file number `index` (0-based) of `count`.
    func begin(_ verb: String, _ url: URL, index: Int, count: Int) {
        begin(verb, ShelfItem(content: .file(url)), index: index, count: count)
    }

    /// Moves on to shelf item number `index` (0-based) of `count`: a file, or a link
    /// that Download Audio is working on.
    func begin(_ verb: String, _ item: ShelfItem, index: Int, count: Int) {
        let name = item.displayName
        model.verb = verb
        model.fileName = name
        model.index = index
        model.count = count
        model.fraction = 0
        model.thumbnail = nil
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        Task {
            let scale = panel.screen?.backingScaleFactor ?? 2
            let thumbnail = await ThumbnailProvider.shared.thumbnail(for: item, size: CGSize(width: 88, height: 88), scale: scale)
            // Unless the job has moved on to the next file meanwhile.
            if model.fileName == name {
                model.thumbnail = thumbnail
            }
        }
    }

    func update(progress: Double) {
        model.fraction = progress
    }

    /// Everything worked: show the tick for a moment, then close.
    func finish() async {
        model.isFinished = true
        try? await Task.sleep(for: .seconds(1.2))
        close()
    }

    func close() {
        panel.close()
    }
}

/// The window never becomes key, so without this the first click on Cancel would
/// only "wake" the window instead of pressing the button.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
