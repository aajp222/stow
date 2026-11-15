import AVFoundation
import Foundation
import Testing
@testable import Stow

/// Runs the video Quick Actions on a short clip made on the spot.
struct VideoActionsTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "StowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A plain grey H.264 clip, 320 x 240 at 30 frames a second.
    private func makeClip(named name: String, seconds: Int) async throws -> URL {
        let url = folder.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<(seconds * 30) {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame % 200), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func seconds(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @Test func tellsVideosFromOtherFiles() {
        #expect(VideoActions.isVideo(URL(filePath: "/tmp/a.mp4")))
        #expect(VideoActions.isVideo(URL(filePath: "/tmp/a.MOV")))
        #expect(!VideoActions.isVideo(URL(filePath: "/tmp/a.png")))
        #expect(!VideoActions.isVideo(URL(filePath: "/tmp/a.m4a")))
    }

    @Test func convertingKeepsLengthAndDoesntScaleUp() async throws {
        let clip = try await makeClip(named: "Clip.mp4", seconds: 2)
        let converted = try await VideoActions.convert(clip, to: .hevc1080, into: folder)
        #expect(converted.lastPathComponent == "Clip (HEVC).mp4")
        #expect(abs(try await seconds(of: converted) - 2) < 0.2)
        let track = try #require(try await AVURLAsset(url: converted).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width <= 320 && size.height <= 240)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(format.mediaSubType == .hevc)
    }

    @Test func trimmingKeepsOnlyTheChosenPart() async throws {
        let clip = try await makeClip(named: "Long.mp4", seconds: 4)
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), end: CMTime(value: 3, timescale: 1))
        let trimmed = try await VideoActions.trim(clip, to: range, into: folder)
        #expect(trimmed.lastPathComponent == "Long (trimmed).mp4")
        #expect(abs(try await seconds(of: trimmed) - 2) < 0.2)
        // Not re-encoded: still H.264.
        let track = try #require(try await AVURLAsset(url: trimmed).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(format.mediaSubType == .h264)
    }

    @Test func aFileThatIsntAVideoIsRefused() async throws {
        let text = folder.appending(path: "Notes.mp4")
        try Data("not a video".utf8).write(to: text)
        await #expect(throws: (any Error).self) {
            try await VideoActions.convert(text, to: .h264At720, into: folder)
        }
    }
}
