import AppKit

/// Download Audio: saves the sound of a YouTube video as an MP3 or M4A, using the
/// yt-dlp, ffmpeg and Deno that MediaTools downloads.
///
/// Downloading from YouTube is against YouTube's terms of service. Stow only does it
/// when you ask for a link you put on the shelf yourself.
enum YouTubeAudio {
    enum Format: String, CaseIterable {
        case mp3
        case m4a

        var title: String {
            switch self {
            case .mp3: "MP3"
            case .m4a: "M4A (AAC)"
            }
        }
    }

    /// Whether `url` is a single YouTube video (a watch page, a Short, a live stream
    /// or a youtu.be link), not a channel or a search.
    nonisolated static func isVideoLink(_ url: URL) -> Bool {
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

    /// The video's ID ("dQw4w9WgXcQ"), from any link isVideoLink accepts.
    nonisolated static func videoID(from url: URL) -> String? {
        guard isVideoLink(url) else { return nil }
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

    /// The video's thumbnail from YouTube's image server, for the progress bubble.
    nonisolated static func thumbnail(for url: URL) async -> NSImage? {
        guard let id = videoID(from: url),
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))),
              let imageURL = URL(string: "https://i.ytimg.com/vi/\(encoded)/mqdefault.jpg"),
              let (data, response) = try? await URLSession.shared.data(from: imageURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }

    /// Downloads the audio of `url` into `folder` and returns the file. `onProgress`
    /// gets 0...1: the download is most of it, the conversion the last bit.
    nonisolated static func download(
        _ url: URL,
        as format: Format,
        into folder: URL,
        onProgress: @escaping @MainActor (Double) -> Void
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
            "--progress-template", "download:stow-progress %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            "--print", "after_move:stow-file %(filepath)s",
            "--ffmpeg-location", MediaTools.folder.path,
            "--js-runtimes", "deno:\(MediaTools.deno.path)",
            "--paths", workFolder.path,
            "--output", "%(title).180B.%(ext)s",
            "--embed-metadata",
            // The video's thumbnail as album art, so the shelf (and Music) show it.
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
            // YouTube usually has AAC audio already, so this is often just a copy.
            arguments += ["--format", "bestaudio[ext=m4a]/bestaudio/best"]
        }
        arguments += ["--", url.absoluteString]

        let result = try await run(arguments, onProgress: onProgress)
        let finished = folder.appending(path: result.lastPathComponent)
        let destination = uniqueURL(for: finished)
        try FileManager.default.moveItem(at: result, to: destination)
        return destination
    }

    /// Runs yt-dlp, passing on its progress, and returns the file it made.
    nonisolated private static func run(_ arguments: [String], onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let process = Process()
        process.executableURL = MediaTools.ytDLP
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Titles in any language come through intact.
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let reader = OutputReader(onProgress: onProgress)
        output.fileHandleForReading.readabilityHandler = { handle in
            reader.receive(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            reader.receive(handle.availableData)
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        reader.receive(output.fileHandleForReading.readDataToEndOfFile())
        reader.receive(errors.fileHandleForReading.readDataToEndOfFile())
        reader.finish()

        try Task.checkCancellation()
        guard status == 0, let file = reader.file, FileManager.default.fileExists(atPath: file.path) else {
            throw YouTubeAudioError.failed(reader.errorMessage)
        }
        return file
    }

    nonisolated private static func uniqueURL(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        var number = 1
        while true {
            let stem = number == 1 ? name : "\(name) \(number)"
            let candidate = folder.appending(path: "\(stem).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            number += 1
        }
    }
}

/// Splits yt-dlp's output into lines and picks out what Stow needs: the progress
/// lines and the finished file (both in the formats Stow asked for) and any errors.
private final class OutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var errors: [String] = []
    private(set) var file: URL?
    private let onProgress: @MainActor (Double) -> Void

    nonisolated init(onProgress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = onProgress
    }

    nonisolated func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            handle(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
    }

    nonisolated func finish() {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty {
            handle(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
    }

    nonisolated var errorMessage: String {
        lock.lock()
        defer { lock.unlock() }
        return errors.last ?? "yt-dlp couldn't download it."
    }

    nonisolated private func handle(_ line: String) {
        if line.hasPrefix("stow-file ") {
            file = URL(filePath: String(line.dropFirst("stow-file ".count)))
            let onProgress = self.onProgress
            Task { @MainActor in onProgress(1) }
        } else if line.hasPrefix("stow-progress ") {
            let numbers = line.split(separator: " ").dropFirst().map { Double($0) }
            guard numbers.count == 3, let downloaded = numbers[0], let total = numbers[1] ?? numbers[2], total > 0 else { return }
            // The download is 90%; converting to MP3 takes the rest.
            let fraction = min(downloaded / total, 1) * 0.9
            let onProgress = self.onProgress
            Task { @MainActor in onProgress(fraction) }
        } else if line.hasPrefix("ERROR:") {
            errors.append(Self.readable(line))
        }
    }

    /// "ERROR: [youtube] dQw4w9WgXcQ: Video unavailable" → "Video unavailable".
    nonisolated private static func readable(_ line: String) -> String {
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

enum YouTubeAudioError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
