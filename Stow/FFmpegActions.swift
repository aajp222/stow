import Foundation

/// The Quick Actions that need ffmpeg, which macOS doesn't come with: MP3 and Ogg
/// Vorbis audio (macOS has no encoder for either), converting video formats
/// QuickTime can't open (MKV, WebM, AVI...), GIFs, and tidying up downloaded videos.
/// ffmpeg is the one MediaTools downloads, the same build Download Audio uses.
///
/// Everything aims for the best quality that's still sensible: LAME's best VBR
/// setting, Vorbis quality 8, x264/x265 at visually lossless settings, Apple's own
/// AAC encoder, and GIFs with a palette made for each clip.
enum FFmpegActions {
    /// Video formats QuickTime can't open but ffmpeg can.
    nonisolated static let otherVideoExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "asf", "ts", "m2ts", "mts", "ogv", "3gp", "3g2", "mpg", "mpeg", "vob", "divx",
    ]

    // MARK: - What's in a file

    nonisolated struct Info: Sendable {
        var duration: Double?
        var videoCodec: String?
        var audioCodec: String?
        var sampleRate: Int?
    }

    /// What ffprobe says about a file. Fields are nil when it can't tell.
    nonisolated static func info(of url: URL) async -> Info {
        let lines = LockedLines()
        try? await ToolProcess.run(MediaTools.ffprobe, [
            "-v", "error",
            "-show_entries", "format=duration:stream=codec_type,codec_name,sample_rate,disposition",
            "-of", "json",
            url.path,
        ], onLine: { lines.append($0) })
        guard let json = try? JSONSerialization.jsonObject(with: Data(lines.joined.utf8)) as? [String: Any] else {
            return Info()
        }
        var info = Info()
        if let format = json["format"] as? [String: Any], let duration = format["duration"] as? String {
            info.duration = Double(duration)
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let disposition = stream["disposition"] as? [String: Any]
            let isCoverArt = (disposition?["attached_pic"] as? Int) == 1
            switch stream["codec_type"] as? String {
            case "video" where info.videoCodec == nil && !isCoverArt:
                info.videoCodec = stream["codec_name"] as? String
            case "audio" where info.audioCodec == nil:
                info.audioCodec = stream["codec_name"] as? String
                info.sampleRate = (stream["sample_rate"] as? String).flatMap(Int.init)
            default:
                break
            }
        }
        return info
    }

    // MARK: - Audio

    /// MP3 (LAME V0, the setting LAME recommends for the best quality) or Ogg Vorbis
    /// (quality 8, about 256 kbit/s), keeping the tags and, for MP3, the cover art.
    nonisolated static func convertAudio(
        _ url: URL,
        to format: VideoActions.AudioFormat,
        into folder: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        let destination = uniqueURL(in: folder, named: name, pathExtension: format.pathExtension)
        let info = await info(of: url)
        var arguments = ["-i", url.path, "-map_metadata", "0"]
        // MP3 tops out at 48 kHz; Vorbis is happy with anything.
        if format == .mp3, let rate = info.sampleRate, rate > 48_000 {
            arguments += ["-ar", "48000"]
        }
        let encoder: [String] = format == .mp3
            ? ["-c:a", "libmp3lame", "-q:a", "0", "-id3v2_version", "3"]
            : ["-c:a", "libvorbis", "-q:a", "8"]
        do {
            // With the cover art (MP3 only; Ogg keeps art differently).
            let cover = format == .mp3 ? ["-map", "0:v:0?", "-c:v", "copy", "-disposition:v", "attached_pic"] : []
            try await runFFmpeg(arguments + ["-map", "0:a:0"] + cover + encoder + [destination.path], duration: info.duration, onProgress: onProgress)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            // Some cover art can't go into an MP3; try once more without it.
            try? FileManager.default.removeItem(at: destination)
            guard format == .mp3 else { throw error }
            try await runFFmpeg(arguments + ["-map", "0:a:0"] + encoder + [destination.path], duration: info.duration, onProgress: onProgress)
        }
        return destination
    }

    // MARK: - Video

    /// Convert Video for files QuickTime can't read. Same presets and sizes as the
    /// built-in path (the long side fits the preset, never scaled up), encoded with
    /// x265/x264 at visually lossless settings and Apple's AAC encoder.
    nonisolated static func convertVideo(
        _ url: URL,
        to preset: VideoActions.Preset,
        into folder: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let name = url.deletingPathExtension().lastPathComponent + " (\(preset.suffix))"
        let info = await info(of: url)
        var arguments = ["-i", url.path, "-map_metadata", "0"]
        let destination: URL
        switch preset {
        case .audioOnly:
            destination = uniqueURL(in: folder, named: name, pathExtension: "m4a")
            arguments += ["-map", "0:a:0", "-vn", "-c:a", "aac_at", "-b:a", "256k"]
        case .hevc1080, .h264At1080, .h264At720:
            guard info.videoCodec != nil else { throw FFmpegActionError.noVideo(url.lastPathComponent) }
            destination = uniqueURL(in: folder, named: name, pathExtension: "mp4")
            let longSide = preset == .h264At720 ? 1280 : 1920
            arguments += [
                "-map", "0:v:0", "-map", "0:a:0?",
                "-vf", fitFilter(longSide: longSide),
                "-pix_fmt", "yuv420p",
            ]
            arguments += preset == .hevc1080
                ? ["-c:v", "libx265", "-crf", "22", "-preset", "medium", "-tag:v", "hvc1", "-x265-params", "log-level=error"]
                : ["-c:v", "libx264", "-crf", "18", "-preset", "slow", "-profile:v", "high"]
            arguments += ["-c:a", "aac_at", "-b:a", "256k", "-movflags", "+faststart"]
        }
        do {
            try await runFFmpeg(arguments + [destination.path], duration: info.duration, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Makes a downloaded video play in QuickTime and everywhere else: an MP4 with
    /// H.264 or HEVC video and AAC sound. Video that's already H.264 or HEVC is copied
    /// untouched; VP9 and AV1 (what YouTube uses above 1080p) become HEVC with the
    /// Mac's hardware encoder at a high quality setting.
    nonisolated static func makePlayableMP4(
        _ url: URL,
        to destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let info = await info(of: url)
        var arguments = ["-i", url.path, "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"]
        if ["h264", "hevc"].contains(info.videoCodec ?? "") {
            arguments += ["-c:v", "copy"]
            if info.videoCodec == "hevc" {
                arguments += ["-tag:v", "hvc1"]
            }
        } else {
            arguments += ["-c:v", "hevc_videotoolbox", "-q:v", "72", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
        }
        arguments += info.audioCodec == "aac" ? ["-c:a", "copy"] : ["-c:a", "aac_at", "-b:a", "256k"]
        arguments += ["-movflags", "+faststart", destination.path]
        do {
            try await runFFmpeg(arguments, duration: info.duration, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - GIF

    /// A GIF of the video, or of `range` (start and end in seconds). It gets a 256-
    /// colour palette made for this clip and error-diffusion dithering, which is what
    /// makes ffmpeg GIFs look far better than most. Long clips get a lower frame rate
    /// and size so the file stays shareable.
    nonisolated static func makeGIF(
        _ url: URL,
        range: ClosedRange<Double>?,
        into folder: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let info = await info(of: url)
        guard info.videoCodec != nil else { throw FFmpegActionError.noVideo(url.lastPathComponent) }
        let length = range.map { $0.upperBound - $0.lowerBound } ?? info.duration ?? 0
        let (fps, width) = length > 30 ? (12, 480) : (length > 12 ? (15, 600) : (20, 720))
        let destination = uniqueURL(in: folder, named: url.deletingPathExtension().lastPathComponent, pathExtension: "gif")
        var arguments: [String] = []
        if let range {
            arguments += ["-ss", String(format: "%.3f", range.lowerBound), "-t", String(format: "%.3f", length)]
        }
        arguments += [
            "-i", url.path,
            "-filter_complex",
            "[0:v:0]fps=\(fps),scale='min(\(width),iw)':-2:flags=lanczos,split[a][b];"
                + "[a]palettegen=stats_mode=diff:max_colors=256[p];"
                + "[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
            "-loop", "0",
            destination.path,
        ]
        do {
            try await runFFmpeg(arguments, duration: length > 0 ? length : nil, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    // MARK: - Running ffmpeg

    /// Scales so the long side is at most `longSide` (never up), keeping the shape,
    /// with even sizes as H.264 and HEVC need.
    nonisolated private static func fitFilter(longSide: Int) -> String {
        "scale='if(gte(iw,ih),min(\(longSide),iw),-2)':'if(gte(iw,ih),-2,min(\(longSide),ih))':flags=lanczos,setsar=1"
    }

    /// Runs ffmpeg with its machine-readable progress on, turning it into 0...1.
    nonisolated private static func runFFmpeg(
        _ arguments: [String],
        duration: Double?,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + arguments
        let progressKeys: Set<String> = ["frame", "fps", "bitrate", "total_size", "out_time_us", "out_time_ms", "out_time",
                                         "dup_frames", "drop_frames", "speed", "progress", "stream_0_0_q", "stream_1_0_q"]
        try await ToolProcess.run(MediaTools.ffmpeg, full, onLine: { line in
            guard let duration, duration > 0,
                  line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                  let microseconds = Double(line.split(separator: "=").last ?? "") else { return }
            let fraction = min(max(microseconds / 1_000_000 / duration, 0), 1)
            Task { @MainActor in onProgress(fraction) }
        }, errorMessage: { lines in
            // The last line that isn't progress output is ffmpeg's error.
            let message = lines.last { line in
                !progressKeys.contains(String(line.split(separator: "=").first ?? "")) && !line.hasPrefix("stream_")
            }
            return message.map { "ffmpeg couldn't do it: \($0)" } ?? "ffmpeg couldn't convert it."
        })
    }

    nonisolated static func uniqueURL(in folder: URL, named name: String, pathExtension: String) -> URL {
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

/// Collects a tool's output lines from whichever thread they arrive on.
nonisolated final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    nonisolated init() {}

    nonisolated func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    nonisolated var joined: String {
        lock.withLock { lines.joined(separator: "\n") }
    }
}

enum FFmpegActionError: LocalizedError {
    case noVideo(String)

    var errorDescription: String? {
        switch self {
        case .noVideo(let name): "“\(name)” has no picture to work with."
        }
    }
}
