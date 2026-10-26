import AppKit
import AppleLookCore
import EventKit
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var draft = AppModel.shared.settings
    @State private var calendars: [EKCalendar] = []
    @State private var hasAccess = AppModel.shared.sync.hasAccess
    @State private var message: String?
    @State private var isError = false
    @State private var working = false
    @State private var confirmRemove = false
    @State private var newCalendarName = "AppleLook"

    var body: some View {
        Form {
            Section {
                TextField("ICS link", text: $draft.feedURL,
                          prompt: Text("https://outlook.office365.com/owa/calendar/…/calendar.ics"))
                Text("In Outlook on the web: Settings → Calendar → Shared calendars → Publish a calendar. Choose your calendar and \"Can view all details\", click Publish, then copy the ICS link.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("1. Your Outlook calendar link")
            }

            Section {
                if hasAccess {
                    Picker("Copy into", selection: $draft.calendarID) {
                        Text("Choose a calendar…").tag("")
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            Text("\(cal.title) (\(cal.source.title))").tag(cal.calendarIdentifier)
                        }
                    }
                    HStack {
                        TextField("New calendar", text: $newCalendarName).labelsHidden().frame(maxWidth: 200)
                        Button("Create New Calendar") { createCalendar() }
                            .disabled(newCalendarName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else if model.sync.accessDenied {
                    Text("AppleLook was not allowed to use your calendars. Turn it on in System Settings, then come back.")
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                } else {
                    Text("AppleLook needs permission to add events to your calendars.")
                    Button("Allow Calendar Access") {
                        Task {
                            hasAccess = await model.sync.requestAccess()
                            if hasAccess {
                                loadCalendars()
                            } else {
                                show("Calendar access wasn't allowed. Turn on AppleLook in System Settings → Privacy & Security → Calendars.", error: true)
                            }
                        }
                    }
                }
            } header: {
                Text("2. The calendar to copy into")
            } footer: {
                Text("Use a separate calendar, then share it with family in the Calendar app. AppleLook only changes events it added itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("3. What others will see") {
                TextField("Label", text: $draft.options.label)
                Toggle("Show meeting titles", isOn: $draft.options.includeTitles)
                Toggle("Show locations (online meetings show as \"Remote\")", isOn: $draft.options.includeLocation)
                Toggle("Include meetings marked Tentative", isOn: $draft.options.includeTentative)
                Toggle("Skip multi-day all-day events (room bookings, trips)", isOn: $draft.options.skipMultidayAllDay)
                LabeledContent("Example", value: Feed.summary(title: "Budget review", options: draft.options))
            }

            Section {
                Toggle("Open AppleLook when I log in", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            } footer: {
                Text("AppleLook lives in the menu bar and copies changes every 15 minutes while your Mac is awake.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Remove AppleLook Events…", role: .destructive) { confirmRemove = true }
                        .disabled(model.settings.calendarID.isEmpty || working)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Preview") { Task { await preview() } }
                        .disabled(!canSave || working)
                    Button("Save and Sync") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave || working)
                }
                if let message {
                    Text(message)
                        .foregroundStyle(isError ? .red : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .onAppear(perform: loadCalendars)
        .confirmationDialog("Remove every event AppleLook added to this calendar?", isPresented: $confirmRemove) {
            Button("Remove Events", role: .destructive) { removeEvents() }
        } message: {
            Text("Your own events are not touched. Syncing again will add them back.")
        }
    }

    private var canSave: Bool { !draft.feedURL.isEmpty && !draft.calendarID.isEmpty && hasAccess }

    private func loadCalendars() {
        guard model.sync.hasAccess else { return }
        hasAccess = true
        calendars = model.sync.writableCalendars()
    }

    private func show(_ text: String, error: Bool = false) {
        message = text
        isError = error
    }

    /// Fix up the link in place; returns false (with a message) if it's unusable.
    private func normalizeLink() -> Bool {
        guard let url = FeedURL.normalize(draft.feedURL) else {
            show(SyncError.badLink.localizedDescription, error: true)
            return false
        }
        draft.feedURL = url.absoluteString
        return true
    }

    private func createCalendar() {
        do {
            let cal = try model.sync.createCalendar(named: newCalendarName.trimmingCharacters(in: .whitespaces))
            loadCalendars()
            draft.calendarID = cal.calendarIdentifier
            show("Created \"\(cal.title)\" in \(cal.source.title).")
        } catch {
            show("Couldn't create the calendar: \(error.localizedDescription)", error: true)
        }
    }

    private func preview() async {
        guard normalizeLink() else { return }
        working = true
        defer { working = false }
        do {
            let r = try await model.sync.run(settings: draft, dryRun: true)
            show("Preview: \(r.desiredCount) events from Outlook. A sync would add \(r.created), change \(r.updated) and remove \(r.deleted).")
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func save() async {
        guard normalizeLink() else { return }
        working = true
        defer { working = false }
        do {
            let note = try await model.apply(draft)
            if let error = model.lastError {
                show(error, error: true)
            } else {
                let r = model.lastResult
                show([note, "Saved. Synced \(r?.desiredCount ?? 0) events (added \(r?.created ?? 0), changed \(r?.updated ?? 0), removed \(r?.deleted ?? 0))."]
                    .compactMap { $0 }.joined(separator: " "))
                if !model.launchAtLogin { model.launchAtLogin = true }
            }
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func removeEvents() {
        do {
            let n = try model.sync.purge(calendarID: model.settings.calendarID)
            show("Removed \(n) events.")
        } catch {
            show(error.localizedDescription, error: true)
        }
    }
}
