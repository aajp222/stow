import AVFoundation
import UniformTypeIdentifiers

/// The video and audio Quick Actions: saving sound files in another format, re-encoding a video to make it smaller or more widely
/// playable (what you'd open HandBrake for) and cutting a piece out of one without
/// re-encoding it (what you'd open LosslessCut for).
///
/// Both use AVFoundation's exporter, which is part of macOS, so they work inside the
/// App Sandbox without bundling or running another program. That also sets the
/// limit: Stow can read what QuickTime Player can (MP4, MOV, M4V...), not MKV or WebM.
enum VideoActions {
    /// What Convert Video can make.
    enum Preset: String, CaseIterable {
        case hevc1080
        case h264At1080
        case h264At720
        case audioOnly

        var title: String {
            switch self {
            case .hevc1080: "Smallest File (HEVC, up to 1080p)"
            case .h264At1080: "Plays Anywhere (H.264, up to 1080p)"
            case .h264At720: "Small and Plays Anywhere (H.264, up to 720p)"
            case .audioOnly: "Audio Only (M4A)"
            }
        }

        /// Added to the file's name, so the result is easy to tell from the original.
        nonisolated var suffix: String {
            switch self {
            case .hevc1080: "HEVC"
            case .h264At1080: "1080p"
            case .h264At720: "720p"
            case .audioOnly: "audio"
            }
        }

        nonisolated var exportPreset: String {
            switch self {
            case .hevc1080: AVAssetExportPresetHEVC1920x1080
            case .h264At1080: AVAssetExportPreset1920x1080
            case .h264At720: AVAssetExportPreset1280x720
            case .audioOnly: AVAssetExportPresetAppleM4A
            }
        }

        nonisolated var fileType: AVFileType {
            self == .audioOnly ? .m4a : .mp4
        }
    }

    /// What Convert Audio can make: every audio format macOS can write by itself,
    /// plus MP3 and Ogg Vorbis, which it can't, so those use ffmpeg (FFmpegActions).
    enum AudioFormat: String, CaseIterable {
        case mp3
        case aac
        case appleLossless
        case flac
        case wav
        case aiff
        case ogg

        var title: String {
            switch self {
            case .mp3: "MP3 (plays anywhere)"
            case .aac: "M4A (AAC, small)"
            case .appleLossless: "Apple Lossless (M4A)"
            case .flac: "FLAC (lossless)"
            case .wav: "WAV (uncompressed)"
            case .aiff: "AIFF (uncompressed)"
            case .ogg: "Ogg Vorbis"
            }
        }

        nonisolated var pathExtension: String {
            switch self {
            case .aac, .appleLossless: "m4a"
            case .flac: "flac"
            case .wav: "wav"
            case .aiff: "aiff"
            case .mp3: "mp3"
            case .ogg: "ogg"
            }
        }

        /// Made with the ffmpeg MediaTools downloads rather than by macOS.
        nonisolated var needsFFmpeg: Bool {
            self == .mp3 || self == .ogg
        }
    }

    nonisolated static func isVideo(_ url: URL) -> Bool {
        needsFFmpeg(url) || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false)
    }

    /// Video QuickTime can't open (MKV, WebM, AVI...), which only ffmpeg can convert.
    nonisolated static func needsFFmpeg(_ url: URL) -> Bool {
        FFmpegActions.otherVideoExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }

    /// Saves the sound file in another format, keeping its sample rate, channels and
    /// (for the lossless formats) bit depth.
    nonisolated static func convertAudio(
        _ url: URL,
        to format: AudioFormat,
        into folder: URL,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        if format.needsFFmpeg {
            return try await FFmpegActions.convertAudio(url, to: format, into: folder, onProgress: onProgress)
        }
        let name = url.deletingPathExtension().lastPathComponent
        let destination = uniqueURL(in: folder, named: name, pathExtension: format.pathExtension)
        if format == .aac {
            // The exporter picks a bit rate and resamples if AAC needs it.
            return try await export(
                url,
                preset: AVAssetExportPresetAppleM4A,
                fileType: .m4a,
                timeRange: nil,
                to: destination,
                onProgress: onProgress
            )
        }
        do {
            try await rewriteAudio(url, as: format, to: destination, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error is CancellationError ? error : VideoActionError.unreadableAudio(url.lastPathComponent)
        }
        return destination
    }

    /// Reads the sound a chunk at a time and writes it back out in `format`. Runs off
    /// the main thread: it's a plain loop, and a long recording takes a while.
    @concurrent
    nonisolated private static func rewriteAudio(
        _ url: URL,
        as format: AudioFormat,
        to destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let source = try AVAudioFile(forReading: url)
        let processing = source.processingFormat
        // 16, 24 or 32 bits like the original; anything else (MP3, AAC...) has no
        // bit depth of its own, so use CD quality.
        let sourceBits = source.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0
        let bits = [16, 24, 32].contains(sourceBits) ? sourceBits : 16
        var settings: [String: Any] = [
            AVSampleRateKey: processing.sampleRate,
            AVNumberOfChannelsKey: processing.channelCount,
        ]
        switch format {
        case .wav, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = bits
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = min(bits, 24)
        case .appleLossless:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = bits
        case .aac, .mp3, .ogg:
            break
        }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: processing.commonFormat,
            interleaved: processing.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: 1 << 16) else {
            throw VideoActionError.unreadableAudio(url.lastPathComponent)
        }
        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            await onProgress(Double(source.framePosition) / Double(max(source.length, 1)))
        }
        output.close()
    }

    /// Re-encodes the video with `preset`. The picture is scaled down to fit the
    /// preset's size if it's bigger, never up. `onProgress` is called on the main
    /// thread with 0...1 as the export goes.
    nonisolated static func convert(
        _ url: URL,
        to preset: Preset,
        into folder: URL,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        // QuickTime can't read it: hand it to ffmpeg when it's there.
        let quickTimeCanRead = await isReadable(url)
        if needsFFmpeg(url) || !quickTimeCanRead, MediaTools.isInstalled {
            return try await FFmpegActions.convertVideo(url, to: preset, into: folder, onProgress: onProgress)
        }
        let name = url.deletingPathExtension().lastPathComponent + " (\(preset.suffix))"
        return try await export(
            url,
            preset: preset.exportPreset,
            fileType: preset.fileType,
            timeRange: nil,
            to: uniqueURL(in: folder, named: name, pathExtension: pathExtension(for: preset.fileType)),
            onProgress: onProgress
        )
    }

    /// Saves the part of the video inside `timeRange` as a new file without
    /// re-encoding: the picture and sound are copied as they are, so nothing is lost
    /// and it takes seconds. The result keeps the original's format where it can
    /// (MP4 and M4V stay as they are; everything else becomes a MOV).
    nonisolated static func trim(
        _ url: URL,
        to timeRange: CMTimeRange,
        into folder: URL,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        let fileType: AVFileType = switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
        let name = url.deletingPathExtension().lastPathComponent + " (trimmed)"
        return try await export(
            url,
            preset: AVAssetExportPresetPassthrough,
            fileType: fileType,
            timeRange: timeRange,
            to: uniqueURL(in: folder, named: name, pathExtension: pathExtension(for: fileType)),
            onProgress: onProgress
        )
    }

    nonisolated private static func export(
        _ url: URL,
        preset: String,
        fileType: AVFileType,
        timeRange: CMTimeRange?,
        to destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoActionError.unreadable(url.lastPathComponent)
        }
        if let timeRange {
            session.timeRange = timeRange
        }
        let progress = Task { @MainActor in
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { progress.cancel() }
        do {
            try await session.export(to: destination, as: fileType)
        } catch {
            // A cancelled or failed export can leave half a file behind.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    nonisolated static func isReadable(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isReadable)) ?? false
    }

    nonisolated private static func pathExtension(for fileType: AVFileType) -> String {
        UTType(fileType.rawValue)?.preferredFilenameExtension ?? "mov"
    }

    /// `folder/name.<extension>`, or "name 2", "name 3"... if taken.
    nonisolated private static func uniqueURL(in folder: URL, named name: String, pathExtension: String) -> URL {
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

enum VideoActionError: LocalizedError {
    case unreadable(String)
    case unreadableAudio(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let name):
            "“\(name)” couldn't be converted. Stow works with sound files Music or QuickTime Player can open, such as WAV, AIFF, MP3, M4A and FLAC."
        case .unreadable(let name):
            "“\(name)” isn't a video Stow can read. It works with what QuickTime Player can open, such as MP4 and MOV."
        }
    }
}
