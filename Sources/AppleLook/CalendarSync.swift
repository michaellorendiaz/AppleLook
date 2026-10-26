import AppleLookCore
import EventKit
import Foundation

struct SyncResult {
    var feedCount = 0
    var desiredCount = 0
    var existingCount = 0
    var created = 0
    var updated = 0
    var deleted = 0
    var warnings: [String] = []

    var logLine: String {
        "feed=\(feedCount) desired=\(desiredCount) existing=\(existingCount)  created=\(created) updated=\(updated) deleted=\(deleted)"
    }
}

enum SyncError: LocalizedError {
    case noAccess
    case calendarMissing
    case badLink
    case feedHTTP(Int)

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "AppleLook isn't allowed to use your calendars. Turn it on in System Settings → Privacy & Security → Calendars."
        case .calendarMissing:
            return "The calendar AppleLook copies into is gone. Pick one in Settings."
        case .badLink:
            return "That doesn't look like a calendar link. Copy the ICS link from Outlook."
        case .feedHTTP(let code) where code == 403 || code == 404:
            return "Outlook says the calendar link no longer works (error \(code)). If you reset or unpublished it, paste the new ICS link in Settings."
        case .feedHTTP(let code):
            return "Outlook didn't send the calendar (error \(code)). AppleLook will try again later."
        }
    }
}

/// Reads and writes the target calendar through EventKit. Events AppleLook owns carry a
/// URL of the form applelook://event/<key>; nothing without that URL is ever changed.
@MainActor
final class CalendarSync {
    let store = EKEventStore()
    static let scheme = "applelook"

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var notAskedYet: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }
    var accessDenied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            Log.info("calendar access \(granted ? "granted" : "not granted")")
            return granted
        } catch {
            Log.error("calendar access request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Calendars AppleLook can write to, iCloud ones first.
    func writableCalendars() -> [EKCalendar] {
        store.refreshSourcesIfNecessary()
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications && $0.type != .birthday && $0.type != .subscription }
            .sorted { (isICloud($0.source) ? 0 : 1, $0.title) < (isICloud($1.source) ? 0 : 1, $1.title) }
    }

    private func isICloud(_ source: EKSource) -> Bool {
        source.sourceType == .calDAV && source.title.localizedCaseInsensitiveContains("iCloud")
    }

    /// Make a new calendar in iCloud (or wherever the default calendar lives).
    func createCalendar(named title: String) throws -> EKCalendar {
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = title
        guard let source = store.sources.first(where: isICloud) ?? store.defaultCalendarForNewEvents?.source else {
            throw SyncError.calendarMissing
        }
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    func run(settings: AppSettings, dryRun: Bool) async throws -> SyncResult {
        guard hasAccess else { throw SyncError.noAccess }
        guard let url = FeedURL.normalize(settings.feedURL) else { throw SyncError.badLink }
        guard let calendar = store.calendar(withIdentifier: settings.calendarID) else { throw SyncError.calendarMissing }

        let text = try await Self.fetch(url)
        let feed = Feed.desiredEvents(from: try ICS.parse(text), options: settings.options)
        feed.warnings.forEach { Log.info("warning: \($0)") }

        let now = Date()
        let o = settings.options
        let (existing, owned, duplicates) = ownedEvents(
            in: calendar,
            from: now.addingTimeInterval(-Double(o.windowBackDays + 1) * 86400),
            to: now.addingTimeInterval(Double(o.windowForwardDays + 1) * 86400))
        let plan = SyncPlan(desired: feed.events, existing: existing)

        var result = SyncResult(feedCount: feed.feedEventCount, desiredCount: feed.events.count,
                                existingCount: existing.count, created: plan.creates.count,
                                updated: plan.updates.count, deleted: plan.deletes.count, warnings: feed.warnings)
        guard !dryRun else { return result }

        for d in plan.creates {
            let ev = EKEvent(eventStore: store)
            ev.calendar = calendar
            fill(ev, with: d)
            try store.save(ev, span: .thisEvent, commit: false)
        }
        for d in plan.updates {
            guard let ev = owned[d.key] else { continue }
            fill(ev, with: d)
            try store.save(ev, span: .thisEvent, commit: false)
        }
        for key in plan.deletes {
            if let ev = owned[key] { try store.remove(ev, span: .thisEvent, commit: false) }
        }
        for ev in duplicates { try store.remove(ev, span: .thisEvent, commit: false) }
        result.deleted += duplicates.count
        try store.commit()
        return result
    }

    /// Delete every event AppleLook created in a calendar. Returns how many.
    func purge(calendarID: String) throws -> Int {
        guard hasAccess, let calendar = store.calendar(withIdentifier: calendarID) else { return 0 }
        var removed = 0
        // EventKit searches at most four years at a time
        let now = Date()
        for (from, to) in [(-729, 0), (0, 729)] {
            let (_, owned, dupes) = ownedEvents(in: calendar,
                                                from: now.addingTimeInterval(Double(from) * 86400),
                                                to: now.addingTimeInterval(Double(to) * 86400))
            for ev in Array(owned.values) + dupes {
                try store.remove(ev, span: .thisEvent, commit: false)
                removed += 1
            }
        }
        try store.commit()
        return removed
    }

    private func ownedEvents(in calendar: EKCalendar, from: Date, to: Date)
        -> ([String: ExistingEvent], [String: EKEvent], [EKEvent]) {
        var existing: [String: ExistingEvent] = [:]
        var owned: [String: EKEvent] = [:]
        var duplicates: [EKEvent] = []
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        for ev in store.events(matching: predicate) {
            guard let url = ev.url, url.scheme == Self.scheme else { continue }
            let key = url.lastPathComponent
            if owned[key] != nil {
                duplicates.append(ev)
                continue
            }
            owned[key] = ev
            existing[key] = snapshot(ev, key: key)
        }
        return (existing, owned, duplicates)
    }

    // All-day events: the core works in UTC midnights, EventKit in local days.
    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func localDay(fromUTC date: Date) -> Date {
        let c = Self.utcCal.dateComponents([.year, .month, .day], from: date)
        return Calendar.current.date(from: c)!
    }

    private func utcDay(fromLocal date: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return Self.utcCal.date(from: c)!
    }

    private func snapshot(_ ev: EKEvent, key: String) -> ExistingEvent {
        var start = ev.startDate!
        var end = ev.endDate!
        if ev.isAllDay {
            // EventKit reports the end of an all-day event as the last day (often 23:59:59)
            start = utcDay(fromLocal: start)
            end = Self.utcCal.date(byAdding: .day, value: 1, to: utcDay(fromLocal: end.addingTimeInterval(-1)))!
            if end <= start { end = Self.utcCal.date(byAdding: .day, value: 1, to: start)! }
        }
        return ExistingEvent(key: key, start: start, end: end, title: ev.title ?? "", location: ev.location ?? "")
    }

    private func fill(_ ev: EKEvent, with d: DesiredEvent) {
        ev.title = d.title
        ev.location = d.location.isEmpty ? nil : d.location
        ev.url = URL(string: "\(Self.scheme)://event/\(d.key)")
        ev.availability = .busy
        ev.isAllDay = d.isAllDay
        if d.isAllDay {
            let lastDay = Self.utcCal.date(byAdding: .day, value: -1, to: d.end) ?? d.start
            ev.startDate = localDay(fromUTC: d.start)
            ev.endDate = localDay(fromUTC: max(lastDay, d.start))
        } else {
            ev.startDate = d.start
            ev.endDate = d.end
        }
    }

    /// Download the feed, retrying briefly: right after wake the network is often not up yet.
    static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("AppleLook/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")
        var attempt = 1
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw SyncError.feedHTTP(http.statusCode)
                }
                return String(decoding: data, as: UTF8.self)
            } catch let error as SyncError {
                throw error
            } catch {
                guard attempt < 3 else { throw error }
                attempt += 1
                try await Task.sleep(for: .seconds(20))
            }
        }
    }
}
