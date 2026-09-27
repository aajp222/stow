import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Stow

/// Runs the Quick Actions on real files in a scratch folder.
struct QuickActionsTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "StowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A solid-colour PNG, with transparency if `transparent`.
    private func makePNG(named name: String, width: Int, height: Int, transparent: Bool = false) throws -> URL {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: transparent ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = folder.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixelSize(of url: URL) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    @Test func convertingMakesAJPEGOfTheSameSize() throws {
        let png = try makePNG(named: "Picture.png", width: 40, height: 30, transparent: true)
        let jpeg = try QuickActions.convert(png, to: .jpeg, into: folder)
        #expect(jpeg.pathExtension == "jpeg" || jpeg.pathExtension == "jpg")
        let (width, height) = try pixelSize(of: jpeg)
        #expect(width == 40)
        #expect(height == 30)
    }

    @Test func makeSmallerLimitsTheLongerSide() throws {
        let png = try makePNG(named: "Big.png", width: 4000, height: 1000)
        let smaller = try QuickActions.makeSmaller(png, into: folder)
        let (width, height) = try pixelSize(of: smaller)
        #expect(width == 2048)
        #expect(height == 512)
        #expect(smaller.lastPathComponent.hasPrefix("Big (smaller)"))
    }

    @Test func combiningMakesOnePagePerImage() throws {
        let first = try makePNG(named: "One.png", width: 20, height: 20)
        let second = try makePNG(named: "Two.png", width: 20, height: 20)
        let pdf = try QuickActions.combineIntoPDF([first, second], into: folder)
        #expect(PDFDocument(url: pdf)?.pageCount == 2)
    }

    @Test func compressingSeveralFilesMakesArchiveZip() throws {
        let a = folder.appending(path: "a.txt")
        let b = folder.appending(path: "b.txt")
        try Data("hello".utf8).write(to: a)
        try Data("there".utf8).write(to: b)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let zip = try QuickActions.compress([a, b], into: output)
        #expect(zip.lastPathComponent == "Archive.zip")
        let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 0)
    }

    @Test func namesDontCollide() throws {
        let png = try makePNG(named: "Same.png", width: 10, height: 10)
        let first = try QuickActions.convert(png, to: .png, into: folder)
        let second = try QuickActions.convert(png, to: .png, into: folder)
        #expect(first != second)
    }
}
