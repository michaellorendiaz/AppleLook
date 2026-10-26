import AppKit
import AppleLookCore
import Foundation
import ServiceManagement

/// Everything the user chooses in Settings. Stored in UserDefaults (~/Library/Preferences,
/// readable only by this user), like the config.json of the script version.
struct AppSettings: Codable, Equatable {
    var feedURL = ""
    var calendarID = ""
    var options: SyncOptions = {
        var o = SyncOptions()
        o.label = "Work"
        return o
    }()

    var isComplete: Bool { !feedURL.isEmpty && !calendarID.isEmpty }

    private static let key = "settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let interval: TimeInterval = 15 * 60

    let sync = CalendarSync()
    let updates = Updates()
    @Published var settings = AppSettings.load()
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastResult: SyncResult?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false
    private var timer: Timer?

    var statusLine: String {
        if isSyncing { return "Syncing…" }
        if !settings.isComplete { return "Not set up yet" }
        guard let lastSync else { return "Waiting for first sync" }
        let time = lastSync.formatted(date: .omitted, time: .shortened)
        if lastError != nil { return "Last sync failed at \(time)" }
        return "Synced at \(time) · \(lastResult?.desiredCount ?? 0) events"
    }

    func start() {
        Log.info("AppleLook \(Bundle.main.shortVersion) started")
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in
                await AppModel.shared.syncNow()
                AppModel.shared.updates.checkDaily()
            }
        }
        updates.checkDaily()
        // Timers don't fire during sleep; sync shortly after waking instead of waiting
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                Log.info("woke from sleep")
                try? await Task.sleep(for: .seconds(15))
                await AppModel.shared.syncNow()
            }
        }
        if settings.isComplete {
            Task {
                // macOS forgets the permission when the app's signature changes (an update
                // built without the stable certificate): ask again instead of just failing
                if sync.notAskedYet { _ = await sync.requestAccess() }
                if sync.hasAccess {
                    await syncNow()
                } else {
                    lastError = SyncError.noAccess.localizedDescription
                    SetupWindow.show()
                }
            }
        } else {
            SetupWindow.show()
        }
    }

    func syncNow() async {
        guard settings.isComplete, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let result = try await sync.run(settings: settings, dryRun: false)
            lastResult = result
            lastError = nil
            Log.info("sync ok: \(result.logLine)")
        } catch {
            lastError = error.localizedDescription
            Log.error("sync FAILED: \(error.localizedDescription)")
        }
        lastSync = Date()
    }

    /// Save new settings. If the calendar changed, AppleLook's events move with it.
    func apply(_ new: AppSettings) async throws -> String? {
        var note: String?
        if !settings.calendarID.isEmpty, new.calendarID != settings.calendarID,
           let removed = try? sync.purge(calendarID: settings.calendarID), removed > 0 {
            note = "Removed \(removed) events from the previous calendar."
            Log.info("removed \(removed) events from previous calendar")
        }
        settings = new
        settings.save()
        await syncNow()
        return note
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.error("login item: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AppleLook.log")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = Data("\(stamp.string(from: Date())) \(level) \(message)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }
}
