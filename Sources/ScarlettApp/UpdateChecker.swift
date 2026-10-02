import Foundation
import Observation

/// Looks up the latest GitHub release so About can offer it, and the
/// Settings buttons can show a dot while one is available.  One small
/// request to the GitHub API at launch, every few hours after, and when
/// Settings opens (at most every few hours); nothing is downloaded or
/// installed.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        /// As tagged, without the leading "v": "0.2.1".
        let version: String
        let url: URL
    }

    /// The latest published release (GitHub's "latest" skips pre-releases
    /// and drafts), once fetched.
    private(set) var latest: Release?

    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var checking = false
    private static let minimumInterval: TimeInterval = 6 * 60 * 60

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/MarecekW/scarlett-mixcontrol-1stgen/releases/latest")!

    private init() {}

    /// The latest release, if it's newer than this build.
    var availableUpdate: Release? {
        guard let latest, Self.isNewer(latest.version, than: AppInfo.version) else { return nil }
        return latest
    }

    /// Check now, then again every few hours while the app runs — it can
    /// sit in the menu bar for days.  Called once at launch.
    func startPeriodicChecks() {
        checkIfNeeded()
        Task {
            while true {
                try? await Task.sleep(for: .seconds(Self.minimumInterval))
                checkIfNeeded()
            }
        }
    }

    /// Check unless one ran recently.  Failures (offline, rate limit) are
    /// silent: there's simply no update shown.
    func checkIfNeeded() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.minimumInterval { return }
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            var request = URLRequest(url: Self.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                  let url = URL(string: release.html_url) else { return }
            lastCheck = Date()
            latest = Release(version: Self.stripV(release.tag_name), url: url)
        }
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
    }

    private static func stripV(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Compare "0.2.1" against this build's version.  Local builds carry a
    /// `git describe` suffix ("0.2.1-9-gabc1234", built after the tag) and
    /// betas a pre-release one ("0.2.0-beta.2", built before it).  A build
    /// without a version ("dev") never reports an update.
    static func isNewer(_ release: String, than current: String) -> Bool {
        guard let r = numericParts(release), let c = numericParts(current) else { return false }
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        // Same version: only a pre-release of it is older — not a build
        // after the tag ("-9-gabc1234") or one with local edits ("-dirty").
        let suffix = current.drop { $0 != "-" }.dropFirst().lowercased()
        return ["alpha", "beta", "rc", "pre"].contains { suffix.hasPrefix($0) }
    }

    private static func numericParts(_ version: String) -> [Int]? {
        let core = version.prefix { $0 != "-" }
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }
}
