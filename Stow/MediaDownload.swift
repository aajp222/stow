import AppKit

/// Download Audio and Download Video: saves what's behind a link (a YouTube video,
/// a SoundCloud track, a Vimeo video...) as an audio file or a video that plays
/// everywhere, using the yt-dlp, ffmpeg and Deno that MediaTools downloads.
///
/// Downloading from most of these sites is against their terms of service. Stow
/// only does it when you ask, for a link you put on the shelf yourself.
enum MediaDownload {
    enum AudioFormat: String, CaseIterable {
        case mp3
        case m4a

        var title: String {
            switch self {
            case .mp3: "MP3"
            case .m4a: "M4A (AAC)"
            }
        }
    }

    enum VideoQuality: String, CaseIterable {
        case best
        case p1080
        case p720

        var title: String {
            switch self {
            case .best: "Best Quality (up to 4K)"
            case .p1080: "1080p"
            case .p720: "720p (smaller)"
            }
        }

        /// yt-dlp's format sort: the highest resolution up to the limit, then the
        /// highest frame rate, and at the same resolution H.264 before VP9/AV1, so
        /// most videos need no converting afterwards.
        nonisolated var formatSort: String {
            switch self {
            case .best: "res,fps,+vcodec,acodec:m4a"
            case .p1080: "res:1080,fps,+vcodec,acodec:m4a"
            case .p720: "res:720,fps,+vcodec,acodec:m4a"
            }
        }
    }

    enum Kind {
        case audio(AudioFormat)
        case video(VideoQuality)
    }

    // MARK: - Which links

    /// Sites Download Audio and Download Video are offered for. yt-dlp knows many
    /// more, but these are the popular ones that mostly work without signing in.
    nonisolated private static let supportedHosts: [String] = [
        "soundcloud.com", "vimeo.com", "bandcamp.com", "x.com", "twitter.com", "reddit.com",
        "tiktok.com", "twitch.tv", "dailymotion.com", "mixcloud.com", "instagram.com", "facebook.com",
        "bilibili.com", "rumble.com", "streamable.com", "archive.org",
    ]

    /// Whether Stow offers to download from `url`: a single YouTube video, or a page
    /// (not just the home page) on one of the sites above.
    nonisolated static func isSupportedLink(_ url: URL) -> Bool {
        if isYouTubeVideo(url) {
            return true
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased(), url.path().count > 1 else { return false }
        if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host) {
            return false
        }
        return supportedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Whether `url` is a single YouTube video (a watch page, a Short, a live stream
    /// or a youtu.be link), not a channel or a search.
    nonisolated static func isYouTubeVideo(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased() else { return false }
        let path = url.path()
        if host == "youtu.be" {
            return path.count > 1
        }
        let youTubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
        guard youTubeHosts.contains(host) else { return false }
        if path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } ?? false
        }
        return ["/shorts/", "/live/"].contains { path.hasPrefix($0) && path.count > $0.count }
    }

    /// The video's ID ("dQw4w9WgXcQ"), from any YouTube video link.
    nonisolated static func youTubeID(from url: URL) -> String? {
        guard isYouTubeVideo(url) else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        if url.host()?.lowercased() == "youtu.be" {
            return parts.first
        }
        if url.path() == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "v" }?.value
        }
        return parts.count >= 2 ? parts[1] : nil
    }

    // MARK: - Thumbnails

    /// A YouTube video's thumbnail straight from YouTube's image server, so the
    /// progress bubble can show it at once. Other sites' thumbnails arrive through
    /// `onThumbnail` once yt-dlp has looked the page up.
    nonisolated static func quickThumbnail(for url: URL) async -> NSImage? {
        guard let id = youTubeID(from: url),
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))),
              let imageURL = URL(string: "https://i.ytimg.com/vi/\(encoded)/mqdefault.jpg") else { return nil }
        return await image(at: imageURL)
    }

    nonisolated static func image(at url: URL) async -> NSImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Downloading

    /// Downloads `url` into `folder` and returns the file. `onProgress` gets 0...1
    /// across the whole job (the download, then any converting); `onThumbnail` gets
    /// the page's thumbnail address once yt-dlp knows it.
    nonisolated static func download(
        _ url: URL,
        as kind: Kind,
        into folder: URL,
        onProgress: @escaping @MainActor (Double) -> Void,
        onThumbnail: @escaping @MainActor (URL) -> Void = { _ in }
    ) async throws -> URL {
        // yt-dlp works in a folder of its own, so a cancelled or failed download
        // leaves nothing half-made next to the batch's finished files.
        let workFolder = folder.appending(path: ".download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }

        var arguments = [
            "--ignore-config",
            "--no-playlist",
            "--no-mtime",
            "--no-warnings",
            "--newline",
            "--progress",
            "--progress-template", "download:stow-progress %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(info.format_id)s",
            "--print", "before_dl:stow-formats %(format_id)s",
            "--print", "before_dl:stow-thumb %(thumbnail)s",
            "--print", "after_move:stow-file %(filepath)s",
            "--ffmpeg-location", MediaTools.folder.path,
            "--js-runtimes", "deno:\(MediaTools.deno.path)",
            "--paths", workFolder.path,
            "--output", "%(title).180B [%(id)s].%(ext)s",
            "--embed-metadata",
        ]
        // How much of the bar the download itself gets; the rest is converting.
        let downloadShare: Double
        switch kind {
        case .audio(let format):
            downloadShare = 0.9
            arguments += [
                // The thumbnail as album art, so the shelf (and Music) show it.
                "--embed-thumbnail",
                "--convert-thumbnails", "jpg",
                "--extract-audio",
                "--audio-format", format.rawValue,
            ]
            switch format {
            case .mp3:
                // The best variable bit rate LAME offers (V0, about 245 kbit/s).
                arguments += ["--format", "bestaudio/best", "--audio-quality", "0"]
            case .m4a:
                // Often AAC already, so this is usually just a copy.
                arguments += ["--format", "bestaudio[ext=m4a]/bestaudio/best"]
            }
        case .video(let quality):
            downloadShare = 0.8
            arguments += [
                "--format", "bv*+ba/b",
                "--format-sort", quality.formatSort,
                "--merge-output-format", "mkv",
            ]
        }
        arguments += ["--", url.absoluteString]

        let reader = YTDLPOutput(downloadShare: downloadShare, onProgress: onProgress, onThumbnail: onThumbnail)
        try await ToolProcess.run(MediaTools.ytDLP, arguments, onLine: reader.handle, errorMessage: YTDLPOutput.errorMessage)
        guard let downloaded = reader.file, FileManager.default.fileExists(atPath: downloaded.path) else {
            throw ToolProcess.Failure(tool: "yt-dlp", message: "yt-dlp didn't save anything.")
        }

        let title = cleanTitle(downloaded.deletingPathExtension().lastPathComponent)
        switch kind {
        case .audio:
            let destination = FFmpegActions.uniqueURL(in: folder, named: title, pathExtension: downloaded.pathExtension)
            try FileManager.default.moveItem(at: downloaded, to: destination)
            return destination
        case .video:
            // Into an MP4 that QuickTime, Photos, iPhones and everything else play.
            let destination = FFmpegActions.uniqueURL(in: folder, named: title, pathExtension: "mp4")
            try await FFmpegActions.makePlayableMP4(downloaded, to: destination) { fraction in
                onProgress(downloadShare + (1 - downloadShare) * fraction)
            }
            return destination
        }
    }

    /// "Song [dQw4w9WgXcQ]" → "Song". The ID is in yt-dlp's file name only so two
    /// videos with the same title can't collide while downloading.
    nonisolated static func cleanTitle(_ name: String) -> String {
        guard name.hasSuffix("]"), let open = name.lastIndex(of: "[") else { return name }
        let trimmed = name[..<open].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }
}

/// Picks out of yt-dlp's output what Stow asked it to print: progress, the formats
/// it chose, the thumbnail and the finished file.
nonisolated private final class YTDLPOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let downloadShare: Double
    private let onProgress: @MainActor (Double) -> Void
    private let onThumbnail: @MainActor (URL) -> Void
    private var parts = 1
    private var finishedParts: [String] = []
    private var currentPart: String?
    private var savedFile: URL?

    nonisolated init(downloadShare: Double, onProgress: @escaping @MainActor (Double) -> Void, onThumbnail: @escaping @MainActor (URL) -> Void) {
        self.downloadShare = downloadShare
        self.onProgress = onProgress
        self.onThumbnail = onThumbnail
    }

    nonisolated var file: URL? {
        lock.withLock { savedFile }
    }

    nonisolated func handle(_ line: String) {
        if line.hasPrefix("stow-file ") {
            lock.withLock { savedFile = URL(filePath: String(line.dropFirst("stow-file ".count))) }
            report(downloadShare)
        } else if line.hasPrefix("stow-formats ") {
            // "137+140": a separate video and audio download, one after the other.
            let count = line.dropFirst("stow-formats ".count).split(separator: "+").count
            lock.withLock { parts = max(count, 1) }
        } else if line.hasPrefix("stow-thumb ") {
            if let url = URL(string: String(line.dropFirst("stow-thumb ".count))), url.scheme?.hasPrefix("http") == true {
                let onThumbnail = self.onThumbnail
                Task { @MainActor in onThumbnail(url) }
            }
        } else if line.hasPrefix("stow-progress ") {
            let fields = line.split(separator: " ").dropFirst().map(String.init)
            guard fields.count >= 3, let downloaded = Double(fields[0]),
                  let total = Double(fields[1]) ?? Double(fields[2]), total > 0 else { return }
            let format = fields.count >= 4 ? fields[3] : ""
            let fraction: Double = lock.withLock {
                if let current = currentPart, current != format, !finishedParts.contains(current) {
                    finishedParts.append(current)
                }
                currentPart = format
                let done = Double(min(finishedParts.count, parts - 1))
                return (done + min(downloaded / total, 1)) / Double(parts)
            }
            report(fraction * downloadShare)
        }
    }

    nonisolated private func report(_ fraction: Double) {
        let onProgress = self.onProgress
        Task { @MainActor in onProgress(fraction) }
    }

    /// "ERROR: [youtube] dQw4w9WgXcQ: Video unavailable" → "Video unavailable".
    nonisolated static func errorMessage(_ lines: [String]) -> String {
        guard let line = lines.last(where: { $0.hasPrefix("ERROR:") }) else {
            return "yt-dlp couldn't download it."
        }
        var message = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
        if message.hasPrefix("["), let end = message.firstIndex(of: "]") {
            message = message[message.index(after: end)...].trimmingCharacters(in: .whitespaces)
            // Then the video's ID and a colon.
            if let colon = message.firstIndex(of: ":"), !message[..<colon].contains(" ") {
                message = message[message.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return message
    }
}
