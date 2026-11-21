import Foundation
import Testing
@testable import Stow

/// Real files make it possible to check both names and contents after a rollback.
struct BatchRenameTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "StowRenameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ name: String, contents: String? = nil) throws -> URL {
        let url = folder.appending(path: name)
        try Data((contents ?? name).utf8).write(to: url)
        return url
    }

    private func contents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func entries() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    @Test func previewNumbersInInputOrderAndKeepsExtensions() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["b.JPG", "a.tar.gz", "README", ".gitignore"].map { folder.appending(path: $0) }
        let pattern = BatchRename.Pattern(baseName: "Holiday", startNumber: 7)
        #expect(BatchRename.newNames(for: urls, pattern: pattern) == ["Holiday 07.JPG", "Holiday 08.gz", "Holiday 09", "Holiday 10"])
        #expect(try entries().isEmpty)
    }

    @Test func paddingWidensForCountAndStartingNumber() {
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = (0..<100).map { folder.appending(path: "\($0).txt") }
        let names = BatchRename.newNames(for: urls, pattern: .init(baseName: "Item"))
        #expect(names.first == "Item 001.txt")
        #expect(names.last == "Item 100.txt")
        #expect(BatchRename.newNames(for: Array(urls.prefix(3)), pattern: .init(baseName: "Item", startNumber: 99)) == ["Item 099.txt", "Item 100.txt", "Item 101.txt"])
    }

    @Test func extensionCanBeRemovedAndZeroIsAllowed() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = try [file("one.jpg"), file("two.txt")]
        let renamed = try BatchRename.rename(sources, pattern: .init(baseName: "File", startNumber: 0, keepExtension: false))
        #expect(renamed.map(\.lastPathComponent) == ["File 00", "File 01"])
        #expect(try contents(renamed[0]) == "one.jpg")
        #expect(try contents(renamed[1]) == "two.txt")
        #expect(try entries() == ["File 00", "File 01"])
    }

    @Test func swapKeepsBothFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try file("File 01.txt", contents: "first")
        let second = try file("File 02.txt", contents: "second")
        let renamed = try BatchRename.rename([second, first], pattern: .init(baseName: "File"))
        #expect(renamed == [first, second])
        #expect(try contents(first) == "second")
        #expect(try contents(second) == "first")
        #expect(try entries() == ["File 01.txt", "File 02.txt"])
    }

    @Test func cycleAndUnchangedNamesAreSafe() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try (1...3).map { try file("File 0\($0).txt", contents: "\($0)") }
        let pattern = BatchRename.Pattern(baseName: "File")
        let rotated = try BatchRename.rename([files[2], files[0], files[1]], pattern: pattern)
        #expect(try rotated.map { try contents($0) } == ["3", "1", "2"])
        #expect(try BatchRename.rename(rotated, pattern: pattern) == rotated)
        #expect(try rotated.map { try contents($0) } == ["3", "1", "2"])
        #expect(try entries().count == 3)
    }

    @Test func outsideConflictLeavesEverythingAlone() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = try [file("one.txt"), file("two.txt")]
        let outside = try file("File 02.txt", contents: "outside")
        #expect(throws: BatchRenameError.self) {
            try BatchRename.rename(sources, pattern: .init(baseName: "File"))
        }
        #expect(try sources.map { try contents($0) } == ["one.txt", "two.txt"])
        #expect(try contents(outside) == "outside")
        #expect(try entries() == ["one.txt", "two.txt", "File 02.txt"])
    }

    @Test(arguments: ["", " \n ", "a/b", "a:b", "a\0b"])
    func invalidNamesAreRefused(_ name: String) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try file("original.txt")
        #expect(throws: BatchRenameError.self) {
            try BatchRename.rename([source], pattern: .init(baseName: name))
        }
        #expect(try entries() == ["original.txt"])
    }

    @Test(arguments: [-1, Int.max])
    func invalidNumberRangesAreRefused(_ start: Int) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = try [file("one"), file("two")]
        #expect(BatchRename.newNames(for: sources, pattern: .init(baseName: "File", startNumber: start)).isEmpty)
        #expect(throws: BatchRenameError.self) {
            try BatchRename.rename(sources, pattern: .init(baseName: "File", startNumber: start))
        }
        #expect(try entries() == ["one", "two"])
    }

    @Test func emptyBatchAndLargestValidNumber() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try BatchRename.rename([], pattern: .init(baseName: "File")).isEmpty)
        let source = try file("source")
        let renamed = try BatchRename.rename([source], pattern: .init(baseName: "File", startNumber: Int.max))
        #expect(renamed[0].lastPathComponent == "File \(Int.max)")
    }

    @Test func missingFilesDuplicatesAndDirectoriesAreRefusedBeforeMoving() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try file("original")
        let directory = folder.appending(path: "subfolder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for sources in [[source, folder.appending(path: "missing")], [source, source], [source, directory]] {
            #expect(throws: BatchRenameError.self) {
                try BatchRename.rename(sources, pattern: .init(baseName: "File"))
            }
            #expect(try contents(source) == "original")
        }
        #expect(try entries() == ["original", "subfolder"])
    }

    @Test func caseOnlyChangesAndSeparateFoldersWork() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try file("file 01.txt")
        let child = folder.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let second = child.appending(path: "second.txt")
        try Data("second".utf8).write(to: second)
        let renamed = try BatchRename.rename([first, second], pattern: .init(baseName: "File"))
        #expect(renamed.map(\.lastPathComponent) == ["File 01.txt", "File 02.txt"])
        #expect(renamed[1].deletingLastPathComponent().path == child.path)
        #expect(try contents(renamed[0]) == "file 01.txt")
        #expect(try contents(renamed[1]) == "second")
    }

    @Test func symbolicLinksMoveWithoutChangingTheirTargets() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try file("target.txt", contents: "untouched")
        let link = folder.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let renamed = try BatchRename.rename([link], pattern: .init(baseName: "Link"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: renamed[0].path) == target.path)
        #expect(try contents(target) == "untouched")
        let dangling = folder.appending(path: "File 01.txt")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing.txt")
        #expect(throws: BatchRenameError.self) {
            try BatchRename.rename([target], pattern: .init(baseName: "File"))
        }
        #expect(try contents(target) == "untouched")
    }

    @Test(arguments: 1...6)
    func failureAtAnyMoveRestoresTheWholeCycle(_ failingMove: Int) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try (1...3).map { try file("File 0\($0).txt", contents: "\($0)") }
        var moves = 0
        #expect(throws: BatchRenameError.self) {
            try BatchRename.rename([files[2], files[0], files[1]], pattern: .init(baseName: "File")) { source, destination in
                moves += 1
                if moves == failingMove { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        #expect(try files.map { try contents($0) } == ["1", "2", "3"])
        #expect(try entries() == ["File 01.txt", "File 02.txt", "File 03.txt"])
    }

    @Test func aConflictAppearingDuringCommitAlsoRollsBack() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try [file("a.txt"), file("b.txt")]
        let outside = folder.appending(path: "File 02.txt")
        var moves = 0
        #expect(throws: BatchRenameError.self) {
            try BatchRename.rename(files, pattern: .init(baseName: "File")) { source, destination in
                moves += 1
                if moves == 4 { try Data("outside".utf8).write(to: outside) }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        #expect(try files.map { try contents($0) } == ["a.txt", "b.txt"])
        #expect(try contents(outside) == "outside")
        #expect(try entries() == ["a.txt", "b.txt", "File 02.txt"])
    }

    @Test func blockedRollbackPreservesDataAndReportsItsLocation() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try file("original.txt", contents: "precious")
        var moves = 0
        do {
            _ = try BatchRename.rename([original], pattern: .init(baseName: "File")) { source, destination in
                moves += 1
                if moves == 2 {
                    try Data("outside".utf8).write(to: original)
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
            Issue.record("The injected failure should stop the rename.")
        } catch BatchRenameError.rollbackFailed(let locations) {
            #expect(locations.count == 1)
            #expect(try contents(try #require(locations.first)) == "precious")
            #expect(try contents(original) == "outside")
            #expect(BatchRenameError.rollbackFailed(locations).localizedDescription.contains(locations[0].path))
        }
    }
}
