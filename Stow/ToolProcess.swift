import Foundation

/// Runs one of the command-line tools MediaTools downloads (yt-dlp, ffmpeg,
/// ffprobe), handing each line of its output to `onLine` as it arrives, and stops it
/// if the Swift task running it is cancelled.
enum ToolProcess {
    struct Failure: LocalizedError {
        let tool: String
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `tool` and waits for it. Throws `CancellationError` if the task was
    /// cancelled, or a `Failure` carrying `errorMessage(lastLines)` if it failed.
    nonisolated static func run(
        _ tool: URL,
        _ arguments: [String],
        onLine: @escaping @Sendable (String) -> Void = { _ in },
        errorMessage: @escaping @Sendable ([String]) -> String = { $0.last ?? "" }
    ) async throws {
        let process = Process()
        process.executableURL = tool
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
        process.standardInput = FileHandle.nullDevice

        let splitter = LineSplitter(onLine: onLine)
        output.fileHandleForReading.readabilityHandler = { splitter.receive($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { splitter.receive($0.availableData) }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
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
        splitter.receive(output.fileHandleForReading.readDataToEndOfFile())
        splitter.receive(errors.fileHandleForReading.readDataToEndOfFile())
        splitter.finish()

        try Task.checkCancellation()
        guard status == 0 else {
            let name = tool.lastPathComponent
            let message = errorMessage(splitter.recentLines)
            throw Failure(tool: name, message: message.isEmpty ? "\(name) stopped with an error." : message)
        }
    }
}

/// Splits a tool's output into lines and keeps the last few for error messages.
nonisolated private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var recent: [String] = []
    private let onLine: @Sendable (String) -> Void

    nonisolated init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    nonisolated var recentLines: [String] {
        lock.withLock { recent }
    }

    nonisolated func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            pending.append(data)
            var lines: [String] = []
            // ffmpeg ends progress lines with \r, everything else with \n.
            while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...end)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
            return lines
        }
        lines.forEach(handle)
    }

    nonisolated func finish() {
        let rest: String? = lock.withLock {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
        if let rest {
            handle(rest)
        }
    }

    nonisolated private func handle(_ line: String) {
        lock.withLock {
            recent.append(line)
            if recent.count > 40 {
                recent.removeFirst(recent.count - 40)
            }
        }
        onLine(line)
    }
}
