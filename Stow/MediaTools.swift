import CryptoKit
import Foundation

/// The command-line programs Download Audio uses, which Stow downloads the first
/// time you need them instead of shipping them inside the app:
///
/// - **yt-dlp**, which fetches the audio. Always the latest release, checked against
///   the release's own SHA2-256SUMS, and updated with `yt-dlp -U` at most once a
///   day, since YouTube changes often and old copies stop working.
/// - **ffmpeg** and **ffprobe**, which yt-dlp uses to make MP3s (macOS has no MP3
///   encoder). Static builds from ffmpeg.martin-riedl.de, pinned to one version and
///   its checksums.
/// - **Deno**, the JavaScript runtime yt-dlp needs for full YouTube support. Pinned
///   like ffmpeg.
///
/// They live in `~/Library/Application Support/Stow/Tools/`. Nothing else uses them.
enum MediaTools {
    nonisolated static let folder = URL.applicationSupportDirectory
        .appending(path: "Stow/Tools", directoryHint: .isDirectory)

    nonisolated static var ytDLP: URL { folder.appending(path: "yt-dlp") }
    nonisolated static var ffmpeg: URL { folder.appending(path: "ffmpeg") }
    nonisolated static var ffprobe: URL { folder.appending(path: "ffprobe") }
    nonisolated static var deno: URL { folder.appending(path: "deno") }

    /// About how much the first download is, for the question Stow asks first.
    static let downloadSizeDescription = "about 150 MB"

    nonisolated static var isInstalled: Bool {
        [ytDLP, ffmpeg, ffprobe, deno].allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Pinned downloads

    private struct PinnedZip {
        let name: String
        let url: URL
        let sha256: String
    }

    nonisolated private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Also true when Stow itself runs under Rosetta.
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    nonisolated private static var pinnedZips: [PinnedZip] {
        let ffmpegBase = "https://ffmpeg.martin-riedl.de/download/macos"
        let denoBase = "https://github.com/denoland/deno/releases/download/v2.9.8"
        if isAppleSilicon {
            return [
                PinnedZip(name: "ffmpeg", url: URL(string: "\(ffmpegBase)/arm64/1795207104_9.1/ffmpeg.zip")!,
                          sha256: "1f66e9a690a7f1c9e60b012379f8869c11818d1797f45b21dbb2f2564ba61ae1"),
                PinnedZip(name: "ffprobe", url: URL(string: "\(ffmpegBase)/arm64/1795207104_9.1/ffprobe.zip")!,
                          sha256: "6ef2df5f575042923a28537ab37adf936f28bf3e7b85de23a1447ed447ec1dbd"),
                PinnedZip(name: "deno", url: URL(string: "\(denoBase)/deno-aarch64-apple-darwin.zip")!,
                          sha256: "9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e"),
            ]
        }
        return [
            PinnedZip(name: "ffmpeg", url: URL(string: "\(ffmpegBase)/amd64/1795212433_9.1/ffmpeg.zip")!,
                      sha256: "35b3d82cccc2c1d644d49d15f5e57eb913a08ef68f798042c90eecec62c51f1e"),
            PinnedZip(name: "ffprobe", url: URL(string: "\(ffmpegBase)/amd64/1795212433_9.1/ffprobe.zip")!,
                      sha256: "41ca7b7cba7992e33f1da3f1bf54db8ec103a4d387b1bfac3162062e8b1074ad"),
            PinnedZip(name: "deno", url: URL(string: "\(denoBase)/deno-x86_64-apple-darwin.zip")!,
                      sha256: "4b2f5edd2639b7470f034238b321d7002d8dfb4726d8558f52c17afac370eb2c"),
        ]
    }

    // MARK: - Installing

    /// Downloads whatever is missing. `onStep` names each tool as it starts (for the
    /// progress window) and `onProgress` reports 0...1 through it.
    nonisolated static func install(
        onStep: @escaping @MainActor (_ name: String, _ index: Int, _ count: Int) -> Void,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let missingZips = pinnedZips.filter { !fileManager.isExecutableFile(atPath: folder.appending(path: $0.name).path) }
        let needsYTDLP = !fileManager.isExecutableFile(atPath: ytDLP.path)
        let count = missingZips.count + (needsYTDLP ? 1 : 0)
        var index = 0

        if needsYTDLP {
            await onStep("yt-dlp", index, count)
            try await installYTDLP(onProgress: onProgress)
            index += 1
        }
        for zip in missingZips {
            try Task.checkCancellation()
            await onStep(zip.name, index, count)
            let downloaded = try await download(zip.url, onProgress: onProgress)
            defer { try? fileManager.removeItem(at: downloaded) }
            guard try sha256(of: downloaded) == zip.sha256 else {
                throw MediaToolsError.checksumMismatch(zip.name)
            }
            try unzipTool(named: zip.name, from: downloaded)
            index += 1
        }
    }

    /// The latest yt-dlp release for macOS, checked against the release's checksums.
    nonisolated private static func installYTDLP(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        // Ask which release is the latest first, so the binary and its checksum
        // file come from the same one even if a new release lands meanwhile.
        let (releaseData, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        struct Release: Decodable { let tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: releaseData).tag_name
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)"

        let (sumsData, _) = try await URLSession.shared.data(from: URL(string: "\(base)/SHA2-256SUMS")!)
        var expected: String?
        for line in String(decoding: sumsData, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[1] == "yt-dlp_macos" {
                expected = String(fields[0])
            }
        }
        guard let expected else { throw MediaToolsError.checksumMismatch("yt-dlp") }

        let downloaded = try await download(URL(string: "\(base)/yt-dlp_macos")!, onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard try sha256(of: downloaded) == expected else {
            throw MediaToolsError.checksumMismatch("yt-dlp")
        }
        try place(downloaded, at: ytDLP)
    }

    /// Unzips `zip` and puts the program called `name` inside it in the Tools folder.
    nonisolated private static func unzipTool(named name: String, from zip: URL) throws {
        let fileManager = FileManager.default
        let unzipped = fileManager.temporaryDirectory.appending(path: "Stow-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: unzipped) }
        // ditto is what Finder's Archive Utility uses; it keeps permissions.
        try runAndWait("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
        guard let found = fileManager.enumerator(at: unzipped, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == name }) else {
            throw MediaToolsError.badDownload(name)
        }
        try place(found, at: folder.appending(path: name))
    }

    /// Moves a downloaded program into place and makes sure macOS will run it:
    /// executable, and signed (Apple silicon refuses unsigned code, so anything that
    /// isn't gets an ad-hoc signature, the same thing `codesign -s -` does).
    nonisolated private static func place(_ file: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: file, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        // Downloads made with URLSession aren't quarantined, but be sure.
        removexattr(destination.path, "com.apple.quarantine", 0)
        if (try? runAndWait("/usr/bin/codesign", ["--verify", destination.path])) == nil {
            try runAndWait("/usr/bin/codesign", ["--force", "--sign", "-", destination.path])
        }
    }

    // MARK: - Updating yt-dlp

    private static let lastUpdateKey = "MediaToolsLastYTDLPUpdate"

    /// Runs `yt-dlp -U` if it hasn't been run in the last day. A failed update isn't
    /// a problem: the copy already there is used.
    static func updateYTDLPIfDue() async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastUpdateKey) as? Date, Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        defaults.set(Date(), forKey: lastUpdateKey)
        let path = ytDLP.path
        _ = try? await Task.detached(priority: .userInitiated) {
            try runAndWait(path, ["-U"])
        }.value
    }

    // MARK: - Helpers

    /// Downloads `url` to a temporary file, reporting progress as it goes.
    nonisolated private static func download(_ url: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a program, waits for it, and throws if it fails.
    @discardableResult
    nonisolated static func runAndWait(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw MediaToolsError.toolFailed(URL(filePath: path).lastPathComponent, text)
        }
        return text
    }
}

/// Reports a download's progress and hands back the finished file, moved out of
/// URLSession's temporary location (which is deleted as soon as the callback returns).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    nonisolated(unsafe) var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @MainActor (Double) -> Void
    nonisolated(unsafe) private var lastReported = 0.0

    nonisolated init(onProgress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = onProgress
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard fraction - lastReported >= 0.01 else { return }
        lastReported = fraction
        let onProgress = self.onProgress
        Task { @MainActor in onProgress(fraction) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            finish(.failure(MediaToolsError.badDownload(downloadTask.originalRequest?.url?.lastPathComponent ?? "A tool")))
            return
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "Stow-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
    }

    nonisolated private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

enum MediaToolsError: LocalizedError {
    case checksumMismatch(String)
    case badDownload(String)
    case toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let name):
            "The download of \(name) didn't match its published checksum, so Stow didn't keep it. Try again later."
        case .badDownload(let name):
            "\(name) couldn't be downloaded. Check your internet connection and try again."
        case .toolFailed(let name, let output):
            "\(name) stopped with an error: \(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))"
        }
    }
}
