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
    // Keyword lists are edited as text, so typing "ART, " doesn't lose the comma
    @State private var skipKeywords = AppModel.shared.settings.options.excludeKeywords.joined(separator: ", ")
    @State private var altKeywords = AppModel.shared.settings.options.altLabelKeywords.joined(separator: ", ")
    @State private var showAdvanced = !AppModel.shared.settings.options.altLabelKeywords.isEmpty

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
                        Spacer()
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
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Event title", text: $draft.options.titleFormat, prompt: Text("Busy"))
                    hint("`{event}` is the meeting's title. Type anything around it, like `Work: {event}` or `{event} (Work)`. Left empty, events show as \"Busy\".")
                }
                Toggle("Show actual meeting/event titles", isOn: variable("{event}", in: \.titleFormat))
                Toggle("Show locations (online meetings show as \"Remote\")", isOn: $draft.options.includeLocation)
                Toggle("Include meetings marked Tentative", isOn: $draft.options.includeTentative)
                Toggle("Include meetings marked Free", isOn: $draft.options.includeFree)
                // Stored as skipMultidayAllDay; shown the other way round, like the options above it
                Toggle("Include multi-day all-day events (room bookings, trips)", isOn: Binding(
                    get: { !draft.options.skipMultidayAllDay }, set: { draft.options.skipMultidayAllDay = !$0 }))
                LabeledContent("Example", value: Feed.summary(title: "Budget review", options: draft.options))
            }

            Section("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Skip meetings whose title contains",
                              text: keywordList($skipKeywords, into: \.excludeKeywords),
                              prompt: Text("Focus time, Lunch"))
                    hint("Separate words with commas. Not case-sensitive.")
                }
            }

            if showAdvanced {
                Section("Alternate Event Titles") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("For events that contain the keyword",
                                  text: keywordList($altKeywords, into: \.altLabelKeywords),
                                  prompt: Text("Enter keyword(s)"))
                        hint("Matches the exact word, including capitalization: \"ART\" matches \"ART show\" and \"ART123\", but not \"Art show\" or \"PARTY\". Separate several keywords with commas.")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("use this event title", text: $draft.options.altTitleFormat, prompt: Text("Same as above"))
                        hint("Works like the event title above, for example `Teaching ({event})`. Left empty, these events use that one.")
                    }
                    Toggle("Show actual meeting/event titles", isOn: variable("{event}", in: \.altTitleFormat))
                    if let keyword = draft.options.altLabelKeywords.first {
                        LabeledContent("Example", value: Feed.summary(title: "\(keyword) 120", options: draft.options))
                    }
                }
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
            } footer: {
                VStack(spacing: 10) {
                    Link(destination: URL(string: "https://buymeacoffee.com/michaellorendiaz")!) {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(Color(red: 1, green: 0.867, blue: 0), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 4) {
                        Text("AppleLook \(Bundle.main.shortVersion) ·")
                        Link("GitHub", destination: Updates.repoURL)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
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

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// A toggle for one variable in a title template: turning it on adds the variable,
    /// turning it off takes it out and tidies; typing the variable ticks it. Same as the
    /// checkboxes on the server's page.
    private func variable(_ token: String, in field: WritableKeyPath<SyncOptions, String>) -> Binding<Bool> {
        Binding(
            get: { draft.options[keyPath: field].contains(token) },
            set: { on in
                let t = draft.options[keyPath: field]
                if on && !t.contains(token) { draft.options[keyPath: field] = Feed.addingVariable(token, to: t) }
                if !on { draft.options[keyPath: field] = Feed.tidyTemplate(t.replacingOccurrences(of: token, with: "")) }
            })
    }

    private func keywordList(_ text: Binding<String>, into field: WritableKeyPath<SyncOptions, [String]>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: {
                text.wrappedValue = $0
                draft.options[keyPath: field] = $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            })
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
