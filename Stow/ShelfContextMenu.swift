import AppKit
import CoreMedia
import UniformTypeIdentifiers

/// Builds the shelf's right-click menus and carries out their commands.
///
/// macOS adds two things itself: "Ask Siri" at the top (macOS 27 puts it in every
/// standard right-click menu) and the Services submenu at the bottom. Services shows
/// up because ShelfCollectionView offers the selected files to it; see its
/// NSServicesMenuRequestor conformance.
final class ShelfContextMenu: NSObject {
    let viewModel: ShelfViewModel
    /// The items the open menu acts on, captured when the menu was built.
    var targets: [ShelfItem] = []
    /// Kept alive while the share menu it shows is on screen.
    private var sharePicker: NSSharingServicePicker?
    /// Where to show the share menu: a view and a rectangle in it (the shelf's list
    /// and the selected row). Set by ShelfViewController.
    var shareAnchor: () -> (view: NSView, rect: NSRect)? = { nil }
    /// The shelf's window, and two things the Download Audio bubble needs from the
    /// list: where an item's row is on screen, and hiding rows until it pours into
    /// them. Set by ShelfViewController.
    var shelfWindow: () -> NSWindow? = { nil }
    var rowScreenFrame: (ShelfItem.ID) -> NSRect? = { _ in nil }
    var setHiddenItems: (Set<ShelfItem.ID>) -> Void = { _ in }
    /// The open Trim Video window and the progress window of a running video action.
    var trimWindow: TrimWindowController?
    var videoTask: Task<Void, Never>?
    /// Folders you've given Stow access to this session (see withFolderAccess).
    private var grantedFolders: [URL] = []

    init(viewModel: ShelfViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    /// The menu for right-clicking `items`, or for empty space on the shelf when
    /// `items` is empty (then only the shelf-wide commands are shown).
    func menu(for items: [ShelfItem]) -> NSMenu {
        targets = items
        let menu = NSMenu()
        // Each item's enabled state is set by hand below.
        menu.autoenablesItems = false

        if !items.isEmpty {
            // File commands only make sense when every selected item is a file.
            let urls = items.compactMap { $0.fileURL }
            let allFiles = urls.count == items.count
            let allLinks = items.allSatisfy { if case .link = $0.content { true } else { false } }

            let openTitle = allLinks ? (items.count == 1 ? "Open Link" : "Open Links") : "Open"
            menu.addItem(makeItem(openTitle, #selector(openItems), enabled: items.contains { Self.canOpen($0) }))
            if allFiles {
                let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                openWith.submenu = makeOpenWithMenu(for: urls)
                menu.addItem(openWith)
            }

            menu.addItem(makeItem("Share…", #selector(shareItems)))

            if allFiles {
                let quickActions = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
                quickActions.submenu = makeQuickActionsMenu(for: urls)
                menu.addItem(quickActions)
                if urls.count == 1 {
                    menu.addItem(makeItem("Rename…", #selector(renameItem)))
                } else {
                    menu.addItem(makeItem("Rename in Order…", #selector(batchRename)))
                }
                menu.addItem(makeItem("Move…", #selector(moveItems)))
            }
            let allLinksOrText = items.allSatisfy { if case .file = $0.content { false } else { true } }
            if allLinksOrText {
                let quickActions = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
                quickActions.submenu = makeLinkQuickActionsMenu(for: allLinks ? items : (items.count == 1 ? items : []))
                menu.addItem(quickActions)
            }
            menu.addItem(makeItem("Copy", #selector(copyItems)))
            if allFiles {
                menu.addItem(makeItem("Show in Finder", #selector(showInFinder)))
            }
            menu.addItem(.separator())
            let allPinned = items.allSatisfy { $0.isPinned }
            menu.addItem(makeItem(allPinned ? "Unpin" : "Pin", allPinned ? #selector(unpinItems) : #selector(pinItems)))
            // Gathering items that are already one whole stack would change nothing.
            let sharedStack = Set(items.map { $0.stackID }).count == 1 ? items[0].stackID : nil
            let isOneStack = sharedStack != nil && stackSize(sharedStack) == items.count
            if items.count >= 2, !isOneStack {
                menu.addItem(makeItem("Stack Items", #selector(stackItems)))
            }
            if items.count >= 3 {
                menu.addItem(makeItem("Stack in Groups…", #selector(stackItemsInGroups)))
            }
            if isOneStack {
                menu.addItem(makeItem("Rename Stack…", #selector(renameStack)))
            }
            if items.contains(where: { $0.stackID.map { stackSize($0) >= 2 } ?? false }) {
                menu.addItem(makeItem("Unstack", #selector(unstackItems)))
            }
            menu.addItem(makeItem("Remove", #selector(removeItems)))
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Restore Last Removed Files", #selector(restoreLastRemoved), enabled: viewModel.canRestoreLastRemoved))
        menu.addItem(makeItem(
            "Add Clipboard Contents to Stow",
            #selector(addClipboardContents),
            // Checks only what kinds of data are on the clipboard, without reading it.
            enabled: PasteboardContents.offersAcceptedTypes(.general)
        ))
        return menu
    }

    /// How many items on the shelf share a stack ID. A "stack" of one shows as an
    /// ordinary item, so it isn't offered Unstack.
    private func stackSize(_ stackID: UUID?) -> Int {
        viewModel.items.filter { $0.stackID == stackID }.count
    }

    func makeItem(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    // MARK: - Share

    /// Shows the system share menu (AirDrop, Mail, Messages...) next to the selection.
    ///
    /// This doesn't use NSSharingServicePicker's ready-made menu item: the share menu
    /// and the windows it opens (the AirDrop and Messages sheets) expect an active app
    /// with a key window, and the shelf is a panel in an app that's normally never
    /// active. So Stow becomes the active app first and shows the picker itself,
    /// pointing at the selection.
    @objc private func shareItems() {
        guard let anchor = shareAnchor(), !targets.isEmpty else {
            NSSound.beep()
            return
        }
        NSApp.activate()
        anchor.view.window?.makeKey()
        let picker = NSSharingServicePicker(items: targets.map { $0.shareableValue })
        sharePicker = picker
        picker.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .minX)
    }

    // MARK: - Quick Actions

    /// Makes new files from the selection: a zip, converted or smaller images, a
    /// cut-out, the text in an image, one PDF, converted video or audio, a GIF. The
    /// originals are left alone; each result lands on the shelf next to them.
    private func makeQuickActionsMenu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let images = urls.filter(QuickActions.isImage)
        let allImages = images.count == urls.count
        let pages = urls.filter { QuickActions.isImage($0) || QuickActions.isPDF($0) }
        let allPages = pages.count == urls.count && !pages.isEmpty

        menu.addItem(makeItem("Compress", #selector(compressItems)))
        menu.addItem(.separator())
        for type in QuickActions.conversionTypes {
            let name = type.preferredFilenameExtension?.uppercased() ?? type.localizedDescription ?? "Image"
            let item = makeItem("Convert to \(name)", #selector(convertItems(_:)), enabled: allImages)
            item.representedObject = type.identifier
            menu.addItem(item)
        }
        menu.addItem(makeItem("Make Smaller", #selector(makeItemsSmaller), enabled: allImages))
        menu.addItem(makeItem("Remove Background", #selector(removeBackground), enabled: allImages))
        menu.addItem(makeItem("Copy Text", #selector(copyText), enabled: allPages))
        menu.addItem(.separator())
        menu.addItem(makeItem("Combine into PDF", #selector(combineIntoPDF), enabled: allPages))
        menu.addItem(.separator())
        // One video or audio job at a time: they use every core as it is.
        let allVideos = urls.allSatisfy(VideoActions.isVideo) && videoTask == nil
        let convertVideo = NSMenuItem(title: "Convert Video", action: nil, keyEquivalent: "")
        convertVideo.isEnabled = allVideos
        convertVideo.submenu = makeSubmenu(VideoActions.Preset.allCases.map { ($0.title, $0.rawValue) }, #selector(convertVideos(_:)))
        menu.addItem(convertVideo)
        // Trimming uses QuickTime's trim bar, so only for videos QuickTime can open.
        let trimmable = allVideos && urls.count == 1 && !VideoActions.needsFFmpeg(urls[0]) && trimWindow == nil
        menu.addItem(makeItem("Trim Video…", #selector(trimVideo), enabled: trimmable))
        menu.addItem(makeItem(urls.count == 1 ? "Make GIF…" : "Make GIFs", #selector(makeGIF), enabled: allVideos && trimWindow == nil))
        let convertAudio = NSMenuItem(title: "Convert Audio", action: nil, keyEquivalent: "")
        convertAudio.isEnabled = urls.allSatisfy(VideoActions.isAudio) && videoTask == nil
        convertAudio.submenu = makeSubmenu(VideoActions.AudioFormat.allCases.map { ($0.title, $0.rawValue) }, #selector(convertAudio(_:)))
        menu.addItem(convertAudio)
        return menu
    }

    /// Quick Actions for links and text: downloading what's behind a link, and a QR
    /// code for one link or piece of text.
    private func makeLinkQuickActionsMenu(for items: [ShelfItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let downloadable = !items.isEmpty && items.allSatisfy { $0.linkURL.map(MediaDownload.isSupportedLink) ?? false }
        if downloadable {
            let audio = NSMenuItem(title: "Download Audio", action: nil, keyEquivalent: "")
            audio.isEnabled = videoTask == nil
            audio.submenu = makeSubmenu(MediaDownload.AudioFormat.allCases.map { ($0.title, $0.rawValue) }, #selector(downloadAudio(_:)))
            menu.addItem(audio)
            let video = NSMenuItem(title: "Download Video", action: nil, keyEquivalent: "")
            video.isEnabled = videoTask == nil
            video.submenu = makeSubmenu(MediaDownload.VideoQuality.allCases.map { ($0.title, $0.rawValue) }, #selector(downloadVideo(_:)))
            menu.addItem(video)
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Make QR Code", #selector(makeQRCode), enabled: items.count == 1))
        return menu
    }

    /// A submenu of choices, each passing its raw value to `action`.
    private func makeSubmenu(_ choices: [(title: String, value: String)], _ action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in choices {
            let item = makeItem(choice.title, action)
            item.representedObject = choice.value
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Downloads

    /// Saves the sound of each link as an audio file.
    @objc private func downloadAudio(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let format = MediaDownload.AudioFormat(rawValue: rawValue) else { return }
        download(.audio(format), failureTitle: "Couldn't download the audio")
    }

    /// Saves each link as a video that plays everywhere.
    @objc private func downloadVideo(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let quality = MediaDownload.VideoQuality(rawValue: rawValue) else { return }
        download(.video(quality), failureTitle: "Couldn't download the video")
    }

    private func download(_ kind: MediaDownload.Kind, failureTitle: String) {
        let links = targets.filter { $0.linkURL != nil }
        guard !links.isEmpty, ensureTools() else { return }
        runVideoAction(
            failureTitle,
            verb: "Downloading",
            items: links,
            anchor: targets.last?.id,
            prepare: prepareTools
        ) { item, folder, job in
            guard let url = item.linkURL else { throw CancellationError() }
            return try await MediaDownload.download(url, as: kind, into: folder, onProgress: job.progress, onThumbnail: job.thumbnail)
        }
    }

    // MARK: - Tools

    /// True if the tools MediaTools downloads are there, or you agreed to download
    /// them now (it happens in `prepareTools`, behind the progress window).
    private func ensureTools() -> Bool {
        if MediaTools.isInstalled {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Download the tools Stow needs for this?"
        alert.informativeText = """
            Downloads and some conversions (MP3, Ogg, MKV, WebM, GIF) use yt-dlp, ffmpeg and \
            Deno. They're free, open-source programs, \(MediaTools.downloadSizeDescription) in all, \
            and Stow keeps them in its own folder. This happens once.

            Downloading from YouTube and most other sites is against their terms of service, \
            so only save what you have the right to.
            """
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        return Dialog.run { alert.runModal() } == .alertFirstButtonReturn
    }

    /// Fetches the tools if they're missing, or keeps yt-dlp up to date if not.
    private var prepareTools: (any JobProgress) async throws -> Void {
        { progress in
            if !MediaTools.isInstalled {
                try await MediaTools.install(
                    onStep: { name, index, count in
                        progress.begin("Getting", ShelfItem(content: .text(name)), index: index, count: count)
                    },
                    onProgress: { progress.update(progress: $0) }
                )
            } else {
                await MediaTools.updateYTDLPIfDue()
            }
        }
    }

    // MARK: - Video and audio

    @objc private func convertVideos(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = VideoActions.Preset(rawValue: rawValue) else { return }
        let urls = targets.compactMap { $0.fileURL }
        // MKV, WebM and the like need ffmpeg.
        let needsTools = urls.contains(where: VideoActions.needsFFmpeg)
        if needsTools, !ensureTools() {
            return
        }
        runVideoAction("Couldn't convert the video", verb: "Converting", urls: urls, anchor: targets.last?.id,
                       prepare: needsTools ? prepareTools : { _ in }) { url, folder, onProgress in
            try await VideoActions.convert(url, to: preset, into: folder, onProgress: onProgress)
        }
    }

    @objc private func convertAudio(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let format = VideoActions.AudioFormat(rawValue: rawValue) else { return }
        let urls = targets.compactMap { $0.fileURL }
        if format.needsFFmpeg, !ensureTools() {
            return
        }
        runVideoAction("Couldn't convert the audio", verb: "Converting", urls: urls, anchor: targets.last?.id,
                       prepare: format.needsFFmpeg ? prepareTools : { _ in }) { url, folder, onProgress in
            try await VideoActions.convertAudio(url, to: format, into: folder, onProgress: onProgress)
        }
    }

    /// Opens the trim window; clicking Trim there saves the kept part as a new file,
    /// without re-encoding.
    @objc private func trimVideo() {
        guard let item = targets.first, let url = item.fileURL else { return }
        let anchor = item.id
        let controller = TrimWindowController(url: url) { [weak self] range in
            self?.runVideoAction("Couldn't trim the video", verb: "Trimming", urls: [url], anchor: anchor) { url, folder, onProgress in
                try await VideoActions.trim(url, to: range, into: folder, onProgress: onProgress)
            }
        } onClose: { [weak self] in
            self?.trimWindow = nil
        }
        trimWindow = controller
        controller.show()
    }

    /// Make GIF…: for one video QuickTime can open, the trim window first, so you
    /// pick the moment; otherwise a GIF of each whole video.
    @objc private func makeGIF() {
        let urls = targets.compactMap { $0.fileURL }
        guard !urls.isEmpty, ensureTools() else { return }
        let anchor = targets.last?.id
        let makeGIFs: (ClosedRange<Double>?) -> Void = { [weak self] range in
            guard let self else { return }
            self.runVideoAction("Couldn't make the GIF", verb: "Making GIF", urls: urls, anchor: anchor,
                                prepare: self.prepareTools) { url, folder, onProgress in
                try await FFmpegActions.makeGIF(url, range: range, into: folder, onProgress: onProgress)
            }
        }
        guard urls.count == 1, !VideoActions.needsFFmpeg(urls[0]) else {
            makeGIFs(nil)
            return
        }
        let controller = TrimWindowController(url: urls[0], title: "Make a GIF from “\(urls[0].lastPathComponent)”") { range in
            makeGIFs(range.start.seconds...range.end.seconds)
        } onClose: { [weak self] in
            self?.trimWindow = nil
        }
        trimWindow = controller
        controller.show()
    }

    // MARK: - Images and text

    /// Lifts the subject out of each photo onto a transparent background.
    @objc private func removeBackground() {
        let urls = targets.compactMap { $0.fileURL }
        runAsyncQuickAction("Couldn't remove the background") { folder in
            var results: [URL] = []
            for url in urls {
                results.append(try await ImageActions.removeBackground(url, into: folder))
            }
            return results
        }
    }

    /// Reads the text in each image or PDF, puts it on the clipboard, and adds it to
    /// the shelf as a text item so you can see what was found.
    @objc private func copyText() {
        let urls = targets.compactMap { $0.fileURL }
        let anchor = targets.last?.id
        Task {
            do {
                var texts: [String] = []
                for url in urls {
                    texts.append(try await ImageActions.recognizeText(in: url))
                }
                let text = texts.joined(separator: "\n\n")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                ClipboardWatcher.markAsStows(pasteboard)
                viewModel.addText(text, after: anchor)
            } catch {
                Dialog.showProblem("Couldn't read the text", details: error.localizedDescription)
            }
        }
    }

    /// A QR code image for the link or text, to drag into a document or a slide.
    @objc private func makeQRCode() {
        guard let item = targets.first else { return }
        let string: String
        let name: String
        switch item.content {
        case .link(let url, let title):
            string = url.absoluteString
            name = MediaDownload.cleanTitle(title ?? url.host() ?? "Link")
        case .text(let text):
            string = text
            name = String(item.displayName.prefix(40))
        case .file:
            return
        }
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        runQuickAction("Couldn't make the QR code") { folder in
            [try ImageActions.qrCode(for: string, into: folder, named: safeName)]
        }
    }

    /// Like runQuickAction, for work that awaits (Vision requests).
    private func runAsyncQuickAction(_ failureTitle: String, _ work: @escaping @Sendable (URL) async throws -> [URL]) {
        let anchor = targets.last?.id
        let folder: URL
        do {
            folder = try PromisedFileStore().makeDropFolder()
        } catch {
            Dialog.showProblem(failureTitle, details: error.localizedDescription)
            return
        }
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) { try await work(folder) }.value
                viewModel.addStowCopies(results, after: anchor)
            } catch {
                Dialog.showProblem(failureTitle, details: error.localizedDescription)
            }
        }
    }

    // MARK: - Running long jobs

    /// What a job reports back as it runs: progress (0...1) and, for downloads, the
    /// thumbnail address once it's known.
    struct JobUpdates {
        let progress: @MainActor @Sendable (Double) -> Void
        let thumbnail: @MainActor @Sendable (URL) -> Void
    }

    /// Runs a video or audio action on each file in turn, with a progress window you
    /// can cancel, and puts each result on the shelf as it finishes.
    private func runVideoAction(
        _ failureTitle: String,
        verb: String,
        urls: [URL],
        anchor: ShelfItem.ID?,
        prepare: @escaping (any JobProgress) async throws -> Void = { _ in },
        _ work: @escaping (URL, URL, @escaping @MainActor (Double) -> Void) async throws -> URL
    ) {
        runVideoAction(
            failureTitle,
            verb: verb,
            items: urls.map { ShelfItem(content: .file($0)) },
            anchor: anchor,
            prepare: prepare
        ) { item, folder, job in
            guard let url = item.fileURL else { throw CancellationError() }
            return try await work(url, folder, job.progress)
        }
    }

    /// The same for any shelf items. `prepare` runs first, behind the same progress
    /// window (downloading the tools, if needed).
    private func runVideoAction(
        _ failureTitle: String,
        verb: String,
        items: [ShelfItem],
        anchor: ShelfItem.ID?,
        prepare: @escaping (any JobProgress) async throws -> Void = { _ in },
        _ work: @escaping (ShelfItem, URL, JobUpdates) async throws -> URL
    ) {
        guard videoTask == nil else {
            NSSound.beep()
            return
        }
        let folder: URL
        do {
            folder = try PromisedFileStore().makeDropFolder()
        } catch {
            Dialog.showProblem(failureTitle, details: error.localizedDescription)
            return
        }
        // The bubble rises out of the shelf and sinks back in before the files
        // appear there. If the shelf isn't on screen (hidden, or you clicked Trim
        // in the trim window after it went away), the floating card is used, and
        // each file is added as soon as it's made.
        let bubble = ShelfProgressBubble(shelfWindow: shelfWindow(), rowScreenFrame: rowScreenFrame, setHiddenItems: setHiddenItems)
        let progress: any JobProgress = bubble ?? VideoProgressPanel()
        videoTask = Task {
            var heldBack: [URL] = []
            defer {
                progress.close()
                videoTask = nil
                // After a failure or Cancel, still add what was finished.
                if !heldBack.isEmpty {
                    viewModel.addStowCopies(heldBack, after: anchor)
                }
            }
            do {
                try await prepare(progress)
                for (index, item) in items.enumerated() {
                    progress.begin(verb, item, index: index, count: items.count)
                    let updates = JobUpdates(
                        progress: { progress.update(progress: $0) },
                        thumbnail: { progress.showThumbnail(at: $0) }
                    )
                    let result = try await work(item, folder, updates)
                    if bubble != nil {
                        heldBack.append(result)
                    } else {
                        viewModel.addStowCopies([result], after: anchor)
                    }
                }
                let results = heldBack
                heldBack = []
                await progress.finish { [viewModel] in
                    viewModel.addStowCopies(results, after: anchor)
                }
            } catch {
                // Cancel isn't a problem to report.
                if !Task.isCancelled {
                    Dialog.showProblem(failureTitle, details: error.localizedDescription)
                }
            }
        }
        progress.show { [weak self] in self?.videoTask?.cancel() }
    }

    @objc private func compressItems() {
        let urls = targets.compactMap { $0.fileURL }
        runQuickAction("Couldn't compress the items") { folder in
            [try QuickActions.compress(urls, into: folder)]
        }
    }

    @objc private func convertItems(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, let type = UTType(identifier) else { return }
        let urls = targets.compactMap { $0.fileURL }
        runQuickAction("Couldn't convert the images") { folder in
            try urls.map { try QuickActions.convert($0, to: type, into: folder) }
        }
    }

    @objc private func makeItemsSmaller() {
        let urls = targets.compactMap { $0.fileURL }
        runQuickAction("Couldn't make the images smaller") { folder in
            try urls.map { try QuickActions.makeSmaller($0, into: folder) }
        }
    }

    @objc private func combineIntoPDF() {
        let urls = targets.compactMap { $0.fileURL }
        runQuickAction("Couldn't combine the items into a PDF") { folder in
            [try QuickActions.combineIntoPDF(urls, into: folder)]
        }
    }

    /// Runs a quick action on a background thread and puts what it made on the shelf,
    /// after the last of the items it was made from. Results go in a fresh folder in
    /// Stow's own storage, so they're Stow copies: cleaned up once removed.
    func runQuickAction(_ failureTitle: String, _ work: @escaping @Sendable (URL) throws -> [URL]) {
        let anchor = targets.last?.id
        let folder: URL
        do {
            folder = try PromisedFileStore().makeDropFolder()
        } catch {
            Dialog.showProblem(failureTitle, details: error.localizedDescription)
            return
        }
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) { try work(folder) }.value
                viewModel.addStowCopies(results, after: anchor)
            } catch {
                Dialog.showProblem(failureTitle, details: error.localizedDescription)
            }
        }
    }

    // MARK: - Open With

    /// Apps that can open every selected file, like Finder's Open With: the default
    /// app first, then the rest alphabetically, then Other….
    private func makeOpenWithMenu(for urls: [URL]) -> NSMenu {
        let workspace = NSWorkspace.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        var apps = workspace.urlsForApplications(toOpen: urls[0])
        for url in urls.dropFirst() {
            let alsoOpens = Set(workspace.urlsForApplications(toOpen: url))
            apps = apps.filter { alsoOpens.contains($0) }
        }
        let defaultApp = workspace.urlForApplication(toOpen: urls[0]).flatMap { apps.contains($0) ? $0 : nil }
        if let defaultApp {
            menu.addItem(makeOpenWithItem(for: defaultApp, suffix: " (default)"))
            menu.addItem(.separator())
        }
        let otherApps = apps
            .filter { $0 != defaultApp }
            .sorted { Self.appName($0).localizedStandardCompare(Self.appName($1)) == .orderedAscending }
        for app in otherApps {
            menu.addItem(makeOpenWithItem(for: app))
        }
        if !otherApps.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Other…", #selector(openWithOtherApp)))
        return menu
    }

    private func makeOpenWithItem(for app: URL, suffix: String = "") -> NSMenuItem {
        let item = makeItem(Self.appName(app) + suffix, #selector(openWithApp(_:)))
        item.representedObject = app
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    private static func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        open(with: app)
    }

    @objc private func openWithOtherApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an app to open the file with."
        guard Dialog.run({ panel.runModal() }) == .OK, let app = panel.url else { return }
        open(with: app)
    }

    private func open(with app: URL) {
        let urls = targets.compactMap { $0.fileURL }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    // MARK: - File commands

    /// Renames the file on disk, not just the shelf item.
    @objc private func renameItem() {
        guard targets.count == 1, let item = targets.first, let url = item.fileURL else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(url.lastPathComponent)”"
        alert.informativeText = "This renames the file itself, wherever it is on your Mac."
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard Dialog.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        let folder = url.deletingLastPathComponent()
        do {
            try withFolderAccess(
                to: folder,
                reason: "To rename “\(url.lastPathComponent)”, Stow needs access to the folder it's in, “\(folder.lastPathComponent)”. Click Allow."
            ) {
                try viewModel.rename(item.id, to: field.stringValue)
            }
        } catch is CancellationError {
            return
        } catch {
            Dialog.showProblem("Couldn't rename “\(url.lastPathComponent)”", details: error.localizedDescription)
        }
    }

    /// Rename in Order…: gives every selected file the same name with a number, in
    /// the order they're on the shelf ("Trip 01", "Trip 02"...). Renames the files
    /// themselves; BatchRename makes sure nothing is overwritten and undoes the
    /// whole batch if any one can't be renamed.
    @objc private func batchRename() {
        let files = targets.filter { $0.fileURL != nil }
        let urls = files.compactMap(\.fileURL)
        guard urls.count >= 2 else { return }
        let suggested = files.first?.stackName ?? urls[0].deletingPathExtension().lastPathComponent
        let nameField = NSTextField(string: suggested)
        let startField = NSTextField(string: "1")
        let preview = NSTextField(labelWithString: "")
        preview.textColor = .secondaryLabelColor
        preview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        preview.lineBreakMode = .byTruncatingMiddle
        let updatePreview = {
            let pattern = BatchRename.Pattern(baseName: nameField.stringValue, startNumber: Int(startField.stringValue) ?? 1)
            let names = BatchRename.newNames(for: urls, pattern: pattern)
            preview.stringValue = names.count > 2 ? "\(names[0]), \(names[1]) … \(names[names.count - 1])" : names.joined(separator: ", ")
        }
        updatePreview()
        let observer = FieldObserver(updatePreview)
        nameField.delegate = observer
        startField.delegate = observer

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Start at:"), startField],
            [NSView(), preview],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        startField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 240).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 84)

        let alert = NSAlert()
        alert.messageText = "Rename \(urls.count) files in order"
        alert.informativeText = "This renames the files themselves, in the order they're on the shelf. Each keeps its extension."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField
        let response = Dialog.run { alert.runModal() }
        withExtendedLifetime(observer) {}
        guard response == .alertFirstButtonReturn else { return }
        guard let start = Int(startField.stringValue.trimmingCharacters(in: .whitespaces)), start >= 0 else {
            Dialog.showProblem("Couldn't rename the files", details: "“Start at” has to be a whole number, such as 1.")
            return
        }
        do {
            let pattern = BatchRename.Pattern(baseName: nameField.stringValue.trimmingCharacters(in: .whitespaces), startNumber: start)
            let renamed = try BatchRename.rename(urls, pattern: pattern)
            viewModel.relocate(files.map(\.id), to: renamed)
        } catch {
            Dialog.showProblem("Couldn't rename the files", details: error.localizedDescription)
        }
    }

    @objc private func moveItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = targets.count == 1
            ? "Choose where to move “\(targets[0].displayName)”."
            : "Choose where to move \(targets.count) items."
        guard Dialog.run({ panel.runModal() }) == .OK, let destination = panel.url else { return }
        var problems: [String] = []
        for item in targets {
            guard let url = item.fileURL else { continue }
            let folder = url.deletingLastPathComponent()
            do {
                try withFolderAccess(
                    to: folder,
                    reason: "To move “\(url.lastPathComponent)”, Stow needs access to the folder it's in, “\(folder.lastPathComponent)”. Click Allow."
                ) {
                    try viewModel.move(item.id, to: destination)
                }
            } catch is CancellationError {
                continue
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty {
            Dialog.showProblem("Some items couldn't be moved", details: problems.joined(separator: "\n"))
        }
    }

    // MARK: - Folder access

    /// Runs `operation`, and if the App Sandbox refuses it for lack of access to
    /// `folder`, asks you to grant access to that folder and tries once more.
    ///
    /// Dropping a file on the shelf gives Stow access to that file only. Renaming or
    /// moving it also changes the folder it's in, and the sandbox won't allow that
    /// until you pick the folder in an Open panel yourself. Stow keeps that access for
    /// the rest of the session, so it asks at most once per folder. Throws
    /// CancellationError if you click Cancel.
    private func withFolderAccess(to folder: URL, reason: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error where Self.isPermissionError(error) {
            let panel = NSOpenPanel()
            panel.message = reason
            panel.prompt = "Allow"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = folder
            guard Dialog.run({ panel.runModal() }) == .OK, let granted = panel.url else {
                throw CancellationError()
            }
            if granted.startAccessingSecurityScopedResource() {
                grantedFolders.append(granted)
            }
            try operation()
        }
    }

    /// Whether `error` means "not allowed" (the sandbox, or ordinary file permissions)
    /// rather than something like a name clash.
    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        let permissionCodes = [Int(EPERM), Int(EACCES)]
        if error.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, permissionCodes.contains(error.code) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, permissionCodes.contains(underlying.code) {
            return true
        }
        return false
    }

    @objc private func copyItems() {
        Self.copy(targets)
    }

    @objc private func openItems() {
        if !Self.open(targets) {
            NSSound.beep()
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(targets.compactMap { $0.fileURL })
    }

    @objc private func pinItems() {
        viewModel.setPinned(Set(targets.map { $0.id }), true)
    }

    @objc private func unpinItems() {
        viewModel.setPinned(Set(targets.map { $0.id }), false)
    }

    /// Names a stack, like "Tax docs". The name shows instead of "5 items".
    @objc private func renameStack() {
        guard let stackID = targets.first?.stackID else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Stack"
        alert.informativeText = "Leave it empty to show the number of items instead."
        let field = NSTextField(string: targets.first?.stackName ?? "")
        field.placeholderString = "\(targets.count) items"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard Dialog.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        viewModel.renameStack(stackID, to: field.stringValue)
    }

    @objc private func stackItems() {
        viewModel.stack(targets.map { $0.id })
    }

    /// Asks how many items each stack should hold, then splits the selection into
    /// stacks of that size.
    @objc private func stackItemsInGroups() {
        let count = targets.count
        let alert = NSAlert()
        alert.messageText = "Stack in Groups"
        alert.informativeText = "How many items in each stack? \(count) items are selected, so groups of 20 would make \(Self.groupSummary(count, in: 20))."
        let field = NSTextField(string: "20")
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        field.formatter = {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            formatter.minimum = 2
            return formatter
        }()
        alert.accessoryView = field
        alert.addButton(withTitle: "Stack")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard Dialog.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        let size = field.integerValue
        guard size >= 2 else {
            NSSound.beep()
            return
        }
        viewModel.stack(targets.map { $0.id }, inGroupsOf: size)
    }

    /// "5 stacks", or "5 stacks and one of 3" when it doesn't divide evenly.
    static func groupSummary(_ count: Int, in size: Int) -> String {
        let full = count / size
        let rest = count % size
        let stacks = full == 1 ? "1 stack" : "\(full) stacks"
        switch (full, rest) {
        case (0, _): return "1 stack of \(count)"
        case (_, 0): return stacks
        case (_, 1): return "\(stacks) and 1 loose item"
        default: return "\(stacks) and one of \(rest)"
        }
    }

    @objc private func unstackItems() {
        viewModel.unstack(targets.map { $0.id })
    }

    @objc private func removeItems() {
        viewModel.remove(Set(targets.map { $0.id }))
    }

    // MARK: - Shared with the keyboard

    /// Puts the items on the clipboard, like ⌘C in Finder: paste files into a Finder
    /// window to copy them there or into Mail to attach them; paste text or a link
    /// anywhere you can type.
    static func copy(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { $0.pasteboardWriter })
        ClipboardWatcher.markAsStows(pasteboard)
    }

    /// Opens files in their default apps and links in the browser, like double-clicking
    /// them in Finder. Text has nothing to open it with. Returns false if nothing opened.
    @discardableResult
    static func open(_ items: [ShelfItem]) -> Bool {
        var opened = false
        for item in items {
            switch item.content {
            case .file(let url), .link(let url, _):
                opened = NSWorkspace.shared.open(url) || opened
            case .text:
                continue
            }
        }
        return opened
    }

    private static func canOpen(_ item: ShelfItem) -> Bool {
        if case .text = item.content { false } else { true }
    }

    // MARK: - Shelf commands

    @objc private func restoreLastRemoved() {
        viewModel.restoreLastRemoved()
    }

    @objc private func addClipboardContents() {
        if !viewModel.addClipboardContents() {
            NSSound.beep()
        }
    }
}

/// Calls `onChange` whenever a text field it's the delegate of is edited (the live
/// preview in Rename in Order…).
private final class FieldObserver: NSObject, NSTextFieldDelegate {
    private let onChange: () -> Void

    init(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange()
    }
}
