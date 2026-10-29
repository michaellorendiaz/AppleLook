import Foundation
import Testing
@testable import AppleLookCore

private let iso = ISO8601DateFormatter()
private let eastern = TimeZone(identifier: "America/New_York")!

/// Expand a rule from a local Eastern start and return "yyyy-MM-dd HH:mm" in Eastern time.
private func expand(_ rule: String, from start: String, through end: String = "2027-12-31T00:00:00Z") -> [String] {
    let parser = ICSDateParser()
    let s = parser.parse(start, tzid: "America/New_York")!
    let r = RRule(rule, start: s, parser: parser)!
    let fmt = DateFormatter()
    fmt.timeZone = eastern
    fmt.dateFormat = "yyyy-MM-dd HH:mm"
    return Recurrence.expand(start: s.date, rule: r, timeZone: eastern, through: iso.date(from: end)!).map(fmt.string)
}

private func event(_ body: String) -> String {
    "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:r1\nSUMMARY:Seminar\nX-MICROSOFT-CDO-BUSYSTATUS:BUSY\n\(body)\nEND:VEVENT\nEND:VCALENDAR"
}

@Suite struct RecurrenceTests {
    @Test func weeklyMultipleDaysKeepsWallClockAcrossDST() {
        // DST ends 2026-11-01; the meeting stays at 9:00 local
        #expect(expand("FREQ=WEEKLY;BYDAY=TU,TH;COUNT=4", from: "20261027T090000")
                == ["2026-10-27 09:00", "2026-10-29 09:00", "2026-11-03 09:00", "2026-11-05 09:00"])
    }

    @Test func everyOtherWeekWithUntil() {
        #expect(expand("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;UNTIL=20261124T140000Z;WKST=SU", from: "20261026T090000")
                == ["2026-10-26 09:00", "2026-11-09 09:00", "2026-11-23 09:00"])
    }

    @Test func dateOnlyUntilIncludesThatDay() {
        #expect(expand("FREQ=DAILY;UNTIL=20261029", from: "20261027T150000")
                == ["2026-10-27 15:00", "2026-10-28 15:00", "2026-10-29 15:00"])
    }

    @Test func weekdaysViaDaily() {
        #expect(expand("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=3", from: "20261030T080000")
                == ["2026-10-30 08:00", "2026-11-02 08:00", "2026-11-03 08:00"])
    }

    @Test func monthlySecondTuesdayBothSpellings() {
        let expected = ["2026-11-10 10:00", "2026-12-08 10:00", "2027-01-12 10:00"]
        #expect(expand("FREQ=MONTHLY;BYDAY=2TU;COUNT=3", from: "20261110T100000") == expected)
        #expect(expand("FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2;COUNT=3", from: "20261110T100000") == expected)
    }

    @Test func monthlyLastFriday() {
        #expect(expand("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3", from: "20261030T120000")
                == ["2026-10-30 12:00", "2026-11-27 12:00", "2026-12-25 12:00"])
    }

    @Test func monthlyOn31stSkipsShortMonths() {
        #expect(expand("FREQ=MONTHLY;BYMONTHDAY=31;COUNT=3", from: "20261031T090000")
                == ["2026-10-31 09:00", "2026-12-31 09:00", "2027-01-31 09:00"])
    }

    @Test func yearlyFourthThursdayOfNovember() {
        #expect(expand("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH;COUNT=2", from: "20261126T120000")
                == ["2026-11-26 12:00", "2027-11-25 12:00"])
    }

    @Test func stopsAtWindowEnd() {
        #expect(expand("FREQ=DAILY", from: "20261027T090000", through: "2026-10-30T00:00:00Z").count == 3)
    }

    @Test func unsupportedRuleFallsBackToFirstOccurrence() {
        let r = Feed.desiredEvents(
            from: try! ICS.parse(event("DTSTART:20261027T130000Z\nDTEND:20261027T140000Z\nRRULE:FREQ=WEEKLY;BYWEEKNO=20")),
            options: SyncOptions(), now: iso.date(from: "2026-10-26T12:00:00Z")!)
        #expect(r.events.count == 1)
        #expect(r.warnings.count == 1)
    }

    @Test func exdateAndMovedOccurrence() {
        let feed = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:series
        SUMMARY:Seminar
        DTSTART;TZID=Eastern Standard Time:20261027T090000
        DTEND;TZID=Eastern Standard Time:20261027T100000
        RRULE:FREQ=WEEKLY;COUNT=4
        EXDATE;TZID=Eastern Standard Time:20261103T090000
        X-MICROSOFT-CDO-BUSYSTATUS:BUSY
        END:VEVENT
        BEGIN:VEVENT
        UID:series
        RECURRENCE-ID;TZID=Eastern Standard Time:20261110T090000
        SUMMARY:Seminar (moved)
        DTSTART;TZID=Eastern Standard Time:20261111T140000
        DTEND;TZID=Eastern Standard Time:20261111T150000
        X-MICROSOFT-CDO-BUSYSTATUS:BUSY
        END:VEVENT
        END:VCALENDAR
        """
        let d = desired(feed, now: iso.date(from: "2026-10-26T12:00:00Z")!) { $0.titleFormat = "{event}" }
        let starts = d.values.sorted { $0.start < $1.start }.map { "\(iso.string(from: $0.start)) \($0.title)" }
        #expect(starts == [
            "2026-10-27T13:00:00Z Seminar",
            "2026-11-11T19:00:00Z Seminar (moved)",
            "2026-11-17T14:00:00Z Seminar",
        ])
    }

    @Test func cancelledOccurrenceIsDropped() {
        let feed = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:s2
        DTSTART:20261027T130000Z
        DTEND:20261027T140000Z
        RRULE:FREQ=DAILY;COUNT=3
        X-MICROSOFT-CDO-BUSYSTATUS:BUSY
        END:VEVENT
        BEGIN:VEVENT
        UID:s2
        RECURRENCE-ID:20261028T130000Z
        STATUS:CANCELLED
        DTSTART:20261028T130000Z
        DTEND:20261028T140000Z
        END:VEVENT
        END:VCALENDAR
        """
        #expect(desired(feed, now: iso.date(from: "2026-10-26T12:00:00Z")!).count == 2)
    }
}

@Suite struct SyncPlanTests {
    private func ev(_ key: String, _ title: String = "Work", hour: Int = 13) -> DesiredEvent {
        let s = iso.date(from: "2026-10-27T\(hour):00:00Z")!
        return DesiredEvent(key: key, start: s, end: s.addingTimeInterval(3600), isAllDay: false, title: title, location: "")
    }

    private func have(_ d: DesiredEvent) -> ExistingEvent {
        ExistingEvent(key: d.key, start: d.start, end: d.end, title: d.title, location: d.location)
    }

    @Test func createsUpdatesDeletes() {
        let plan = SyncPlan(
            desired: ["a": ev("a"), "b": ev("b", "Work (Renamed)"), "c": ev("c")],
            existing: ["b": have(ev("b")), "c": have(ev("c")), "z": have(ev("z"))])
        #expect(plan.creates.map(\.key) == ["a"])
        #expect(plan.updates.map(\.key) == ["b"])
        #expect(plan.deletes == ["z"])
    }

    @Test func secondRunIsEmpty() {
        let d = ["a": ev("a"), "b": ev("b", hour: 15)]
        #expect(SyncPlan(desired: d, existing: d.mapValues(have)).isEmpty)
    }
}
