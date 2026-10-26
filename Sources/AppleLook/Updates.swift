import AppKit
import AppleLookCore
import Foundation

/// Checks GitHub for a newer release. There's no auto-install: the user downloads the
/// zip and replaces the app, and their settings carry over.
@MainActor
final class Updates: ObservableObject {
    static let repo = "michaellorendiaz/AppleLook"
    static let downloadURL = URL(string: "https://github.com/\(repo)/releases/latest/download/AppleLook.zip")!
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases/latest")!

    struct Release {
        let version: String
        let notesURL: URL
    }

    /// Set when GitHub has a newer version than this one.
    @Published private(set) var available: Release?
    private var lastCheck: Date?

    func checkDaily() {
        guard lastCheck.map({ Date().timeIntervalSince($0) > 86400 }) ?? true else { return }
        Task { _ = try? await check() }
    }

    func check() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AppleLook/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Latest: Decodable { let tag_name: String; let html_url: URL }
        let latest = try JSONDecoder().decode(Latest.self, from: data)
        lastCheck = Date()
        let release = Release(version: Version.parts(latest.tag_name).map(String.init).joined(separator: "."),
                              notesURL: latest.html_url)
        available = Version.isNewer(latest.tag_name, than: Bundle.main.shortVersion) ? release : nil
        if let available { Log.info("update available: \(available.version)") }
        return available
    }

    /// "Check for Updates…" from the menu: always says something.
    func checkInteractively() async {
        let alert = NSAlert()
        do {
            if let release = try await check() {
                alert.messageText = "AppleLook \(release.version) is available"
                alert.informativeText = "You have \(Bundle.main.shortVersion). " + Self.howToUpdate
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "What's New")
                alert.addButton(withTitle: "Later")
            } else {
                alert.messageText = "AppleLook is up to date"
                alert.informativeText = "You have the latest version, \(Bundle.main.shortVersion)."
            }
        } catch {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Check your internet connection and try again."
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn where available != nil: download()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(available?.notesURL ?? Self.releasesURL)
        default: break
        }
    }

    func download() {
        NSWorkspace.shared.open(Self.downloadURL)
    }

    static let howToUpdate = """
        To update: quit AppleLook from its menu, open the downloaded AppleLook.zip, and drag \
        the new AppleLook into Applications, choosing Replace. Your settings are kept.
        """
}
