import AppKit

/// Tells people who downloaded Stow from GitHub when there's a newer version, by
/// asking GitHub for the latest release. Copies from the App Store or TestFlight are
/// kept up to date by the App Store, so they never check.
///
/// It only reads the public release list: nothing about you or your Mac is sent.
final class UpdateChecker {
    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        /// "v1.3" → "1.3".
        var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/aajp222/stow/releases/latest")!
    private static let lastAnnouncedKey = "LastAnnouncedUpdate"

    private let settings: AppSettings
    /// A newer release, once one has been found. The menu bar menu offers it.
    private(set) var availableUpdate: Release?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// App Store and TestFlight copies carry a receipt inside the app; copies built
    /// in Xcode or downloaded from GitHub don't.
    static var isAppStoreCopy: Bool {
        let receipt = Bundle.main.bundleURL.appending(path: "Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receipt.path)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Checks quietly, at most once a day, if "Check for updates automatically" is on.
    /// A new version is announced once; after that it waits in the menu bar menu.
    func checkIfDue() {
        guard !Self.isAppStoreCopy, settings.checkForUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        Task {
            await check(userInitiated: false)
        }
    }

    /// Check for Updates…: says what it found either way.
    func check(userInitiated: Bool) async {
        settings.lastUpdateCheck = Date()
        let release: Release
        do {
            release = try await fetchLatestRelease()
        } catch {
            if userInitiated {
                Dialog.showProblem("Couldn't check for updates", details: error.localizedDescription)
            }
            return
        }
        guard Self.isVersion(release.version, newerThan: Self.currentVersion) else {
            availableUpdate = nil
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = "Stow is up to date"
                alert.informativeText = "You have the latest version, \(Self.currentVersion)."
                _ = Dialog.run { alert.runModal() }
            }
            return
        }
        availableUpdate = release
        let defaults = UserDefaults.standard
        if userInitiated || defaults.string(forKey: Self.lastAnnouncedKey) != release.version {
            defaults.set(release.version, forKey: Self.lastAnnouncedKey)
            offer(release)
        }
    }

    /// Asks whether to download a new version, and opens its release page if so.
    func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Stow \(release.version) is available"
        alert.informativeText = "You have \(Self.currentVersion). Download the new version, quit Stow, and replace it in your Applications folder."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if Dialog.run({ alert.runModal() }) == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Compares versions like "1.10" and "1.9" number by number ("1.10" is newer).
    static func isVersion(_ version: String, newerThan other: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }
        return false
    }
}
