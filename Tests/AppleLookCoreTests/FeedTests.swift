import Foundation
import Testing
@testable import AppleLookCore

// Same fixture and expectations as outlook-icloud-bridge's tests/test_bridge.py
let NOW = ISO8601DateFormatter().date(from: "2026-03-02T12:00:00Z")!

let FEED = """
BEGIN:VCALENDAR
VERSION:2.0
PRODID:test
BEGIN:VEVENT
UID:busy-1
SUMMARY:Budget review
LOCATION:Room 204
DTSTART:20260303T150000Z
DTEND:20260303T160000Z
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
BEGIN:VEVENT
UID:free-1
SUMMARY:Lunch hold
DTSTART:20260303T170000Z
DTEND:20260303T180000Z
X-MICROSOFT-CDO-BUSYSTATUS:FREE
END:VEVENT
BEGIN:VEVENT
UID:cancel-1
SUMMARY:Cancelled sync
STATUS:CANCELLED
DTSTART:20260304T150000Z
DTEND:20260304T160000Z
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
BEGIN:VEVENT
UID:tent-1
SUMMARY:Maybe meeting
LOCATION:https://teams.microsoft.com/l/meetup-join/abc
DTSTART:20260305T150000Z
DTEND:20260305T160000Z
X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE
END:VEVENT
BEGIN:VEVENT
UID:multi-1
SUMMARY:Room booking
DTSTART;VALUE=DATE:20260306
DTEND;VALUE=DATE:20260313
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
BEGIN:VEVENT
UID:allday-1
SUMMARY:Offsite
DTSTART;VALUE=DATE:20260310
DTEND;VALUE=DATE:20260311
X-MICROSOFT-CDO-BUSYSTATUS:OOF
END:VEVENT
BEGIN:VEVENT
UID:weekly-1
SUMMARY:Team standup
DTSTART:20260302T140000Z
DTEND:20260302T143000Z
RRULE:FREQ=WEEKLY;COUNT=3
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
BEGIN:VEVENT
UID:private-1
SUMMARY:Doctor appointment
DTSTART:20260311T150000Z
DTEND:20260311T160000Z
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
END:VCALENDAR
"""

func desired(_ feed: String = FEED, now: Date = NOW, _ tweak: (inout SyncOptions) -> Void = { _ in }) -> [String: DesiredEvent] {
    var o = SyncOptions()
    tweak(&o)
    return Feed.desiredEvents(from: try! ICS.parse(feed), options: o, now: now).events
}

func titles(_ d: [String: DesiredEvent]) -> [String] { d.values.map(\.title).sorted() }

let withTitles: (inout SyncOptions) -> Void = { $0.includeTitles = true; $0.label = "" }

@Suite struct BridgeParityTests {
    @Test func defaultsArePrivateBusyBlocks() {
        let d = desired()
        #expect(d.count == 8)  // busy-1, tent-1, multi-1, allday-1, 3x weekly, private-1
        #expect(Set(titles(d)) == ["Busy"])
        #expect(d.values.allSatisfy { $0.location.isEmpty })
    }

    @Test func freeAndCancelledAreNeverSynced() {
        let t = titles(desired { withTitles(&$0) })
        #expect(!t.contains("Lunch hold"))
        #expect(!t.contains("Cancelled sync"))
    }

    @Test func titlesAndLabel() {
        #expect(titles(desired { $0.label = "Work"; $0.includeTitles = true }).contains("Work (Budget review)"))
        #expect(titles(desired { withTitles(&$0) }).contains("Budget review"))
    }

    @Test func locationAndRemote() {
        let locs = Set(desired { $0.includeLocation = true }.values.map(\.location))
        #expect(locs.contains("Room 204"))
        #expect(locs.contains("Remote"))
        let raw = desired { $0.includeLocation = true; $0.onlineAsRemote = false }
        #expect(raw.values.contains { $0.location.hasPrefix("https://") })
    }

    @Test func tentativeToggle() {
        #expect(!titles(desired { withTitles(&$0); $0.includeTentative = false }).contains("Maybe meeting"))
    }

    @Test func skipMultidayAllDayKeepsSingleDay() {
        let t = titles(desired { withTitles(&$0); $0.skipMultidayAllDay = true })
        #expect(!t.contains("Room booking"))
        #expect(t.contains("Offsite"))
    }

    @Test func excludeKeywords() {
        #expect(!titles(desired { withTitles(&$0); $0.excludeKeywords = ["doctor"] }).contains("Doctor appointment"))
    }

    @Test func recurrenceExpandedWithStableKeys() {
        #expect(titles(desired { withTitles(&$0) }).filter { $0 == "Team standup" }.count == 3)
        #expect(Set(desired().keys) == Set(desired().keys))
    }

    @Test func windowLimits() {
        #expect(desired { $0.windowForwardDays = 2 }.count == 2)  // busy-1 + first standup
    }

    @Test func keyMatchesBridgeHash() {
        // python3 -c 'import hashlib; print(hashlib.sha1(b"busy-1|2026-03-03T15:00:00+00:00").hexdigest()[:24])'
        let start = ISO8601DateFormatter().date(from: "2026-03-03T15:00:00Z")!
        #expect(Feed.stableKey(sourceUID: "busy-1", start: start) == "806b48cbd3d7fb943b002213")
    }
}

@Suite struct ParsingTests {
    @Test func foldedLinesAndEscapes() throws {
        let cal = try ICS.parse("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Budget\\, Q3\r\n  review\\nfollow-up\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        #expect(cal.children[0].text("SUMMARY") == "Budget, Q3 review\nfollow-up")
    }

    @Test func quotedParamWithColon() throws {
        let cal = try ICS.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART;TZID=\"Eastern Standard Time\":20261104T090000\nEND:VEVENT\nEND:VCALENDAR")
        #expect(cal.children[0].first("DTSTART")?.params["TZID"] == "Eastern Standard Time")
    }

    @Test func notACalendar() {
        #expect(throws: ICSError.self) { try ICS.parse("<html><body>Sign in</body></html>") }
    }

    @Test func everyWindowsZoneResolves() {
        for (win, iana) in TimeZones.windows {
            #expect(TimeZone(identifier: iana) != nil, "\(win) -> \(iana)")
        }
    }

    @Test func windowsZoneGivesCorrectInstant() {
        let p = ICSDateParser()
        // 9:00 Eastern is 13:00 UTC in summer and 14:00 UTC in winter
        let summer = p.parse("20261020T090000", tzid: "Eastern Standard Time")!.date
        let winter = p.parse("20261110T090000", tzid: "Eastern Standard Time")!.date
        #expect(summer == ISO8601DateFormatter().date(from: "2026-10-20T13:00:00Z"))
        #expect(winter == ISO8601DateFormatter().date(from: "2026-11-10T14:00:00Z"))
        #expect(p.unknownZones.isEmpty)
    }

    @Test func feedURLs() {
        #expect(FeedURL.normalize(" https://x.example/owa/calendar/a/b/calendar.html ")?.absoluteString
                == "https://x.example/owa/calendar/a/b/calendar.ics")
        #expect(FeedURL.normalize("webcal://x.example/c.ics")?.absoluteString == "https://x.example/c.ics")
        #expect(FeedURL.normalize("not a link") == nil)
        #expect(FeedURL.normalize("ftp://x.example/c.ics") == nil)
    }
}
