import AppKit
import SwiftUI

@main
struct AppleLookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("AppleLook", systemImage: model.lastError == nil ? "calendar.badge.clock" : "calendar.badge.exclamationmark") {
            MenuContent(model: model, updates: model.updates)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: Updates

    var body: some View {
        if let release = updates.available {
            Button("Update Available: AppleLook \(release.version)…") { Task { await updates.checkInteractively() } }
            Divider()
        }
        Text(model.statusLine)
        if let error = model.lastError {
            Text(error)
        }
        Divider()
        Button("Sync Now") { Task { await model.syncNow() } }
            .disabled(!model.settings.isComplete || model.isSyncing)
        Button("Settings…") { SetupWindow.show() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { Task { await updates.checkInteractively() } }
        Divider()
        Button("Quit AppleLook") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The setup/settings window. Managed by hand so it can open on first launch
/// without opening on every login.
@MainActor
enum SetupWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: SetupView(model: .shared))
            // A grouped Form scrolls and has no natural height; sizing the window from it
            // (sizingOptions = .preferredContentSize) crashes AppKit's layout pass
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "AppleLook Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 560, height: 720))
            w.contentMinSize = NSSize(width: 560, height: 420)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // A menu-bar app isn't frontmost, and macOS 14+ may decline a polite activate(),
        // which leaves the window hidden behind other apps
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
