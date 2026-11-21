import Foundation
import Testing
@testable import Stow

/// The Quick Actions that use the downloaded ffmpeg, run on real clips ffmpeg makes
/// itself. They only run where the tools are installed (not on CI).
@Suite(.enabled(if: MediaTools.isInstalled))
struct FFmpegActionsTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "StowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A 2-second test pattern with a tone, in whatever `codec` and container.
    private func makeClip(named name: String, video: [String], audio: [String], size: String = "1280x720") async throws -> URL {
        let url = folder.appending(path: name)
        try await ToolProcess.run(MediaTools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
        ] + video + audio + ["-shortest", url.path])
        return url
    }

    @Test func convertsAnMKVQuickTimeCantOpen() async throws {
        let mkv = try await makeClip(named: "Clip.mkv", video: ["-c:v", "libvpx-vp9", "-b:v", "1M"], audio: ["-c:a", "libopus"])
        #expect(VideoActions.needsFFmpeg(mkv))
        let result = try await VideoActions.convert(mkv, to: .h264At720, into: folder)
        #expect(result.pathExtension == "mp4")
        let info = await FFmpegActions.info(of: result)
        #expect(info.videoCodec == "h264")
        #expect(info.audioCodec == "aac")
        #expect(abs((info.duration ?? 0) - 2) < 0.2)
        #expect(await VideoActions.isReadable(result))
    }

    @Test func makesAGIFOfPartOfAVideo() async throws {
        let mp4 = try await makeClip(named: "Clip.mp4", video: ["-c:v", "libx264"], audio: ["-c:a", "aac"])
        var progress: [Double] = []
        let gif = try await FFmpegActions.makeGIF(mp4, range: 0.5...1.5, into: folder) { progress.append($0) }
        #expect(gif.pathExtension == "gif")
        let info = await FFmpegActions.info(of: gif)
        #expect(info.videoCodec == "gif")
        let data = try Data(contentsOf: gif)
        #expect(data.starts(with: Array("GIF89a".utf8)))
        // 720 px wide at most.
        let width = Int(data[6]) | Int(data[7]) << 8
        #expect(width == 720)
    }

    @Test func turnsVP9IntoHEVCThatQuickTimePlays() async throws {
        let mkv = try await makeClip(named: "Download.mkv", video: ["-c:v", "libvpx-vp9", "-b:v", "1M"], audio: ["-c:a", "libopus"])
        let mp4 = folder.appending(path: "Download.mp4")
        try await FFmpegActions.makePlayableMP4(mkv, to: mp4) { _ in }
        let info = await FFmpegActions.info(of: mp4)
        #expect(info.videoCodec == "hevc")
        #expect(info.audioCodec == "aac")
        #expect(await VideoActions.isReadable(mp4))
    }

    @Test func copiesH264WithoutReencoding() async throws {
        let mkv = try await makeClip(named: "Already.mkv", video: ["-c:v", "libx264"], audio: ["-c:a", "aac"])
        let mp4 = folder.appending(path: "Already.mp4")
        try await FFmpegActions.makePlayableMP4(mkv, to: mp4) { _ in }
        let info = await FFmpegActions.info(of: mp4)
        #expect(info.videoCodec == "h264")
        // A copy is close to the original's size; a re-encode wouldn't be.
        let original = try FileManager.default.attributesOfItem(atPath: mkv.path)[.size] as? Int ?? 0
        let copy = try FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? Int ?? 0
        #expect(abs(original - copy) < original / 10)
    }

    @Test func recognisesSupportedLinks() {
        #expect(MediaDownload.isSupportedLink(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
        #expect(MediaDownload.isSupportedLink(URL(string: "https://soundcloud.com/artist/track")!))
        #expect(MediaDownload.isSupportedLink(URL(string: "https://artist.bandcamp.com/track/song")!))
        #expect(MediaDownload.isSupportedLink(URL(string: "https://vimeo.com/76979871")!))
        #expect(!MediaDownload.isSupportedLink(URL(string: "https://vimeo.com/")!))
        #expect(!MediaDownload.isSupportedLink(URL(string: "https://www.youtube.com/@channel")!))
        #expect(!MediaDownload.isSupportedLink(URL(string: "https://example.com/video")!))
        #expect(MediaDownload.cleanTitle("Song [dQw4w9WgXcQ]") == "Song")
        #expect(MediaDownload.cleanTitle("[Live] Song") == "[Live] Song")
    }
}
