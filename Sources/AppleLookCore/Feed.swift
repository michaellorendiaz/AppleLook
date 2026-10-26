import CryptoKit
import Foundation

/// What gets copied and how it's labelled. Defaults match bridge.py's.
public struct SyncOptions: Codable, Equatable, Sendable {
    public var label = "Busy"
    public var includeTitles = false
    public var includeLocation = false
    public var onlineAsRemote = true
    public var includeTentative = true
    /// Copy events marked Free too (bridge.py never does). They're shown as free time.
    public var includeFree = false
    public var skipMultidayAllDay = false
    public var excludeKeywords: [String] = []
    public var windowBackDays = 7
    public var windowForwardDays = 90

    public init() {}

    // Options missing from saved settings (added in a later version) keep their defaults,
    // rather than failing to decode and losing everything the user set
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SyncOptions()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? d.label
        includeTitles = try c.decodeIfPresent(Bool.self, forKey: .includeTitles) ?? d.includeTitles
        includeLocation = try c.decodeIfPresent(Bool.self, forKey: .includeLocation) ?? d.includeLocation
        onlineAsRemote = try c.decodeIfPresent(Bool.self, forKey: .onlineAsRemote) ?? d.onlineAsRemote
        includeTentative = try c.decodeIfPresent(Bool.self, forKey: .includeTentative) ?? d.includeTentative
        includeFree = try c.decodeIfPresent(Bool.self, forKey: .includeFree) ?? d.includeFree
        skipMultidayAllDay = try c.decodeIfPresent(Bool.self, forKey: .skipMultidayAllDay) ?? d.skipMultidayAllDay
        excludeKeywords = try c.decodeIfPresent([String].self, forKey: .excludeKeywords) ?? d.excludeKeywords
        windowBackDays = try c.decodeIfPresent(Int.self, forKey: .windowBackDays) ?? d.windowBackDays
        windowForwardDays = try c.decodeIfPresent(Int.self, forKey: .windowForwardDays) ?? d.windowForwardDays
    }
}

/// One event as it should exist in the target calendar.
public struct DesiredEvent: Equatable, Sendable {
    /// Stable ID derived from the Outlook UID and start time.
    public let key: String
    public let start: Date
    /// Exclusive end. All-day events run from midnight UTC to midnight UTC.
    public let end: Date
    public let isAllDay: Bool
    public let title: String
    public let location: String
    /// Marked Free in Outlook (only copied when includeFree is on).
    public let isFree: Bool

    public init(key: String, start: Date, end: Date, isAllDay: Bool, title: String, location: String, isFree: Bool = false) {
        self.key = key
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.title = title
        self.location = location
        self.isFree = isFree
    }
}

public struct FeedResult: Sendable {
    public let events: [String: DesiredEvent]
    /// Number of VEVENTs in the feed, before expanding and filtering.
    public let feedEventCount: Int
    /// Things worth logging: unknown time zones, repeat rules that couldn't be expanded.
    public let warnings: [String]
}

public enum Feed {
    static let busyStatuses: Set<String> = ["BUSY", "TENTATIVE", "OOF", "WORKINGELSEWHERE"]

    public static func desiredEvents(from calendar: ICSComponent, options: SyncOptions, now: Date = Date()) -> FeedResult {
        let windowStart = now.addingTimeInterval(-Double(options.windowBackDays) * 86400)
        let windowEnd = now.addingTimeInterval(Double(options.windowForwardDays) * 86400)
        let parser = ICSDateParser()
        var warnings: [String] = []
        let vevents = calendar.children.filter { $0.name == "VEVENT" }

        // Modified occurrences of a series come as extra VEVENTs with a RECURRENCE-ID
        var masters: [ICSComponent] = []
        var overrides: [String: [Date: ICSComponent]] = [:]
        for ev in vevents {
            if let rid = ev.first("RECURRENCE-ID"), let r = parser.parse(rid) {
                overrides[ev.text("UID"), default: [:]][r.date] = ev
            } else {
                masters.append(ev)
            }
        }

        var occurrences: [(event: ICSComponent, uid: String, start: Date, end: Date, allDay: Bool)] = []
        func span(of ev: ICSComponent) -> (ICSDate, TimeInterval)? {
            guard let dtstart = ev.first("DTSTART"), let s = parser.parse(dtstart) else { return nil }
            if let dtend = ev.first("DTEND"), let e = parser.parse(dtend) {
                return (s, e.date.timeIntervalSince(s.date))
            }
            if let dur = ev.first("DURATION"), let d = parseDuration(dur.value) {
                return (s, d)
            }
            return (s, s.isAllDay ? 86400 : 30 * 60)
        }

        for ev in masters {
            let uid = ev.text("UID")
            guard let (s, duration) = span(of: ev) else { continue }
            var starts = [s.date]
            if let rrule = ev.first("RRULE") {
                if let rule = RRule(rrule.value, start: s, parser: parser) {
                    starts = Recurrence.expand(start: s.date, rule: rule, timeZone: s.timeZone, through: windowEnd)
                } else {
                    warnings.append("Couldn't expand repeat rule \(rrule.value); only its first meeting is copied.")
                }
                starts += ev.all("RDATE").flatMap(parser.parseList).map(\.date)
            }
            let excluded = Set(ev.all("EXDATE").flatMap(parser.parseList).map(\.date))
            let moved = overrides[uid] ?? [:]
            for start in Set(starts) where !excluded.contains(start) && moved[start] == nil {
                occurrences.append((ev, uid, start, start.addingTimeInterval(duration), s.isAllDay))
            }
        }
        for (uid, byStart) in overrides {
            for ev in byStart.values {
                guard let (s, duration) = span(of: ev) else { continue }
                occurrences.append((ev, uid, s.date, s.date.addingTimeInterval(duration), s.isAllDay))
            }
        }

        var desired: [String: DesiredEvent] = [:]
        for occ in occurrences {
            let overlaps = occ.end > occ.start
                ? occ.end > windowStart && occ.start < windowEnd
                : occ.start >= windowStart && occ.start < windowEnd
            guard overlaps, shouldCopy(occ.event, options) else { continue }
            if options.skipMultidayAllDay && occ.allDay && occ.end.timeIntervalSince(occ.start) > 86400 { continue }
            let title = occ.event.text("SUMMARY").trimmingCharacters(in: .whitespacesAndNewlines)
            if isExcluded(title, options) { continue }
            let key = stableKey(sourceUID: occ.uid, start: occ.start)
            desired[key] = DesiredEvent(
                key: key, start: occ.start, end: occ.end, isAllDay: occ.allDay,
                title: summary(title: title, options: options),
                location: cleanLocation(occ.event.text("LOCATION"), options),
                isFree: isFree(occ.event))
        }
        for zone in parser.unknownZones.sorted() {
            warnings.append("Unknown time zone \"\(zone)\"; using this Mac's time zone for it.")
        }
        return FeedResult(events: desired, feedEventCount: vevents.count, warnings: warnings)
    }

    /// Busy, out-of-office and (optionally) tentative events; Free ones only when asked.
    /// Cancelled events never.
    static func shouldCopy(_ ev: ICSComponent, _ o: SyncOptions) -> Bool {
        let status = ev.text("STATUS").uppercased()
        if status == "CANCELLED" { return false }
        let cdo = ev.text("X-MICROSOFT-CDO-BUSYSTATUS").uppercased()
        if !cdo.isEmpty {
            if cdo == "TENTATIVE" && !o.includeTentative { return false }
            if cdo == "FREE" { return o.includeFree }
            return busyStatuses.contains(cdo)
        }
        if status == "TENTATIVE" && !o.includeTentative { return false }
        return !isFree(ev) || o.includeFree
    }

    static func isFree(_ ev: ICSComponent) -> Bool {
        let cdo = ev.text("X-MICROSOFT-CDO-BUSYSTATUS").uppercased()
        if !cdo.isEmpty { return cdo == "FREE" }
        return (ev.first("TRANSP")?.value.uppercased() ?? "OPAQUE") == "TRANSPARENT"
    }

    static func isExcluded(_ title: String, _ o: SyncOptions) -> Bool {
        let low = title.lowercased()
        return o.excludeKeywords.contains { !$0.isEmpty && low.contains($0.lowercased()) }
    }

    /// Room or building names pass through; meeting links optionally become "Remote".
    static func cleanLocation(_ raw: String, _ o: SyncOptions) -> String {
        guard o.includeLocation else { return "" }
        let loc = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loc.isEmpty else { return "" }
        let low = loc.lowercased()
        if o.onlineAsRemote && (low.contains("http") || low.contains("teams.microsoft") || low.contains("zoom.us")) {
            return "Remote"
        }
        return loc
    }

    /// "Label (Title)", "Label", or just "Title" when the label is empty.
    public static func summary(title: String, options o: SyncOptions) -> String {
        let label = o.label.trimmingCharacters(in: .whitespaces)
        let shown = o.includeTitles ? title : ""
        if !label.isEmpty && !shown.isEmpty { return "\(label) (\(shown))" }
        if !label.isEmpty { return label }
        return shown.isEmpty ? "Busy" : shown
    }

    /// Same hash as bridge.py's stable_uid (without its salt, prefix and suffix),
    /// so the two can be compared event for event.
    public static func stableKey(sourceUID: String, start: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let iso = String(format: "%04d-%02d-%02dT%02d:%02d:%02d+00:00",
                         c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        let digest = Insecure.SHA1.hash(data: Data("\(sourceUID)|\(iso)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}

public enum FeedURL {
    /// Clean up a pasted link. Outlook's Publish screen shows an HTML and an ICS link that
    /// differ only in the extension, so the HTML one is quietly switched to ICS.
    public static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        if s.hasSuffix("/calendar.html") { s = String(s.dropLast(".html".count)) + ".ics" }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}
