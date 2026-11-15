import AVFoundation
import UniformTypeIdentifiers

/// The video Quick Actions: re-encoding a video to make it smaller or more widely
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

    nonisolated static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
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
        let name = url.deletingPathExtension().lastPathComponent + " (\(preset.suffix))"
        return try await export(
            url,
            preset: preset.exportPreset,
            fileType: preset.fileType,
            timeRange: nil,
            to: uniqueURL(in: folder, named: name, fileType: preset.fileType),
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
            to: uniqueURL(in: folder, named: name, fileType: fileType),
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

    /// `folder/name.<extension>`, or "name 2", "name 3"... if taken.
    nonisolated private static func uniqueURL(in folder: URL, named name: String, fileType: AVFileType) -> URL {
        let pathExtension = UTType(fileType.rawValue)?.preferredFilenameExtension ?? "mov"
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

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            "“\(name)” isn't a video Stow can read. It works with what QuickTime Player can open, such as MP4 and MOV."
        }
    }
}
