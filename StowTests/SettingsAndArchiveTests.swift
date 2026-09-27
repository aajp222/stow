import CoreGraphics
import Foundation
import Testing
@testable import Stow

struct SettingsTests {
    private func freshSettings() -> (AppSettings, UserDefaults) {
        let suite = "StowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test func theShortcutStartsAsControlOptionS() {
        let (settings, _) = freshSettings()
        #expect(settings.shortcut == KeyCombo.default)
    }

    @Test func aTurnedOffShortcutStaysOff() {
        let (settings, _) = freshSettings()
        settings.shortcut = nil
        #expect(settings.shortcut == nil)
        let custom = KeyCombo(keyCode: 1, modifiers: 256, display: "⌘S")
        settings.shortcut = custom
        #expect(settings.shortcut == custom)
    }

    @Test func theOldScreenEdgeSettingCarriesOver() {
        let (settings, defaults) = freshSettings()
        #expect(settings.shelfTrigger == .anyDrag)
        defaults.set(true, forKey: "ShowOnlyAtScreenEdge")
        #expect(settings.shelfTrigger == .screenEdge)
        settings.shelfTrigger = .shake
        #expect(settings.shelfTrigger == .shake)
    }
}

struct ArchiveTests {
    @Test func textLinksPinsAndStackNamesSurviveARelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "StowTests-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let stack = UUID()
        let items = [
            ShelfItem(content: .text("hello"), stackID: stack, stackName: "Bits", isPinned: true),
            ShelfItem(content: .link(URL(string: "https://example.com")!, title: "Example"), stackID: stack, stackName: "Bits"),
            ShelfItem(content: .text("loose")),
        ]
        ShelfArchive(fileURL: file).save(items)
        let loaded = ShelfArchive(fileURL: file).load()
        #expect(loaded == items)
    }

    @Test func aMissingArchiveMeansAnEmptyShelf() {
        let file = FileManager.default.temporaryDirectory.appending(path: "StowTests-missing-\(UUID().uuidString).plist")
        #expect(ShelfArchive(fileURL: file).load().isEmpty)
    }
}

struct UpdateCheckerTests {
    @Test func versionsCompareNumberByNumber() {
        #expect(UpdateChecker.isVersion("1.10", newerThan: "1.9"))
        #expect(UpdateChecker.isVersion("2", newerThan: "1.9.9"))
        #expect(UpdateChecker.isVersion("1.2.1", newerThan: "1.2"))
        #expect(!UpdateChecker.isVersion("1.2", newerThan: "1.2.0"))
        #expect(!UpdateChecker.isVersion("1.1", newerThan: "1.2"))
    }

    @Test func releaseTagsLoseTheirV() throws {
        let json = #"{"tag_name": "v1.3", "html_url": "https://github.com/aajp222/stow/releases/tag/v1.3"}"#
        let release = try JSONDecoder().decode(UpdateChecker.Release.self, from: Data(json.utf8))
        #expect(release.version == "1.3")
    }
}

struct ShakeDetectorTests {
    /// Feeds x positions sixty times a second.
    private func detects(_ xs: [CGFloat]) -> Bool {
        var detector = ShakeDetector()
        var shaken = false
        for (index, x) in xs.enumerated() {
            shaken = detector.add(CGPoint(x: x, y: 300), at: Double(index) / 60) || shaken
        }
        return shaken
    }

    /// A swing of `distance` points over `frames` frames, from `start`.
    private func swing(from start: CGFloat, by distance: CGFloat, frames: Int = 6) -> [CGFloat] {
        (1...frames).map { start + distance * CGFloat($0) / CGFloat(frames) }
    }

    @Test func aQuickShakeIsNoticed() {
        var xs: [CGFloat] = [500]
        for index in 0..<5 {
            xs += swing(from: xs.last!, by: index.isMultiple(of: 2) ? 80 : -80)
        }
        #expect(detects(xs))
    }

    @Test func draggingAcrossTheScreenIsNotAShake() {
        let xs = (0..<120).map { CGFloat($0) * 8 }
        #expect(!detects(xs))
    }

    @Test func aTremorIsNotAShake() {
        let xs = (0..<120).map { CGFloat(500 + ($0.isMultiple(of: 2) ? 3 : -3)) }
        #expect(!detects(xs))
    }
}
