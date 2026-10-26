import Foundation

/// The subset of RFC 5545 RRULE that Outlook writes: DAILY/WEEKLY/MONTHLY/YEARLY with
/// INTERVAL, COUNT, UNTIL, BYDAY (with ordinals), BYMONTHDAY, BYMONTH, BYSETPOS and WKST.
/// Anything else makes `init` fail, and the caller falls back to the first occurrence.
public struct RRule: Sendable, Equatable {
    public enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    public struct WeekdayNum: Sendable, Equatable {
        public var ordinal: Int  // 0 = every such weekday; 2 = second; -1 = last
        public var weekday: Int  // Calendar numbering: 1 = Sunday ... 7 = Saturday
    }

    public var frequency: Frequency
    public var interval = 1
    public var count: Int?
    public var until: Date?
    public var byDay: [WeekdayNum] = []
    public var byMonthDay: [Int] = []
    public var byMonth: [Int] = []
    public var bySetPos: [Int] = []
    public var weekStart = 2  // Monday

    static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// `start` is the event's DTSTART; a date-only UNTIL is read in its zone.
    public init?(_ text: String, start: ICSDate, parser: ICSDateParser = ICSDateParser()) {
        var freq: Frequency?
        for part in text.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).uppercased() }
            guard kv.count == 2 else { return nil }
            let (key, value) = (kv[0], kv[1])
            let ints = { value.split(separator: ",").compactMap { Int($0) } }
            switch key {
            case "FREQ":
                guard let f = Frequency(rawValue: value) else { return nil }
                freq = f
            case "INTERVAL":
                guard let n = Int(value), n > 0 else { return nil }
                interval = n
            case "COUNT":
                guard let n = Int(value), n > 0 else { return nil }
                count = n
            case "UNTIL":
                guard let u = parser.parse(value, tzid: nil, defaultZone: start.timeZone) else { return nil }
                // A date-only UNTIL includes that whole day
                until = u.isAllDay && !start.isAllDay
                    ? makeDate(value, endOfDayIn: start.timeZone) ?? u.date
                    : u.date
            case "BYDAY":
                for item in value.split(separator: ",") {
                    let code = String(item.suffix(2))
                    guard let wd = Self.weekdays[code] else { return nil }
                    let ord = item.dropLast(2)
                    guard ord.isEmpty || Int(ord) != nil else { return nil }
                    byDay.append(WeekdayNum(ordinal: Int(ord) ?? 0, weekday: wd))
                }
            case "BYMONTHDAY": byMonthDay = ints()
            case "BYMONTH": byMonth = ints()
            case "BYSETPOS": bySetPos = ints()
            case "WKST":
                guard let wd = Self.weekdays[value] else { return nil }
                weekStart = wd
            default:
                return nil  // BYHOUR, BYWEEKNO, BYYEARDAY, ...: not something Outlook publishes
            }
        }
        guard let freq else { return nil }
        // Yearly rules that pick days without naming a month are rare and unsupported
        if freq == .yearly && byMonth.isEmpty && (!byDay.isEmpty || !byMonthDay.isEmpty) { return nil }
        frequency = freq
    }
}

private func makeDate(_ yyyymmdd: String, endOfDayIn zone: TimeZone) -> Date? {
    let v = Array(yyyymmdd.utf8)
    guard v.count >= 8,
          let y = Int(String(decoding: v[0..<4], as: UTF8.self)),
          let m = Int(String(decoding: v[4..<6], as: UTF8.self)),
          let d = Int(String(decoding: v[6..<8], as: UTF8.self)) else { return nil }
    return AppleLookCore.makeDate(y, m, d, 23, 59, 59, in: zone)
}

public enum Recurrence {
    static let maxPeriods = 20_000

    /// Start times of every occurrence from `start` up to and including `through`.
    /// Wall-clock times are kept in `timeZone`, so a 9:00 meeting stays at 9:00 across DST.
    public static func expand(start: Date, rule: RRule, timeZone: TimeZone, through end: Date) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = rule.weekStart
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: start)
        guard let y0 = c.year, let m0 = c.month, let d0 = c.day, let wd0 = c.weekday else { return [start] }
        let (h, mi, s) = (c.hour ?? 0, c.minute ?? 0, c.second ?? 0)

        func at(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))
        }
        func ymd(_ date: Date) -> (Int, Int, Int) {
            let x = cal.dateComponents([.year, .month, .day], from: date)
            return (x.year!, x.month!, x.day!)
        }
        // The day numbers in one month picked by BYMONTHDAY / BYDAY (or DTSTART's day)
        func monthDays(_ y: Int, _ m: Int) -> [Int] {
            guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)),
                  let n = cal.range(of: .day, in: .month, for: first)?.count else { return [] }
            let firstWeekday = cal.component(.weekday, from: first)
            var days = Set<Int>()
            for md in rule.byMonthDay {
                let v = md > 0 ? md : n + md + 1
                if (1...n).contains(v) { days.insert(v) }
            }
            if !rule.byDay.isEmpty {
                var picked = Set<Int>()
                for wn in rule.byDay {
                    let matches = (1...n).filter { (firstWeekday - 1 + $0 - 1) % 7 + 1 == wn.weekday }
                    if wn.ordinal == 0 {
                        picked.formUnion(matches)
                    } else if wn.ordinal > 0, wn.ordinal <= matches.count {
                        picked.insert(matches[wn.ordinal - 1])
                    } else if wn.ordinal < 0, -wn.ordinal <= matches.count {
                        picked.insert(matches[matches.count + wn.ordinal])
                    }
                }
                days = rule.byMonthDay.isEmpty ? picked : days.intersection(picked)
            }
            if rule.byMonthDay.isEmpty && rule.byDay.isEmpty && d0 <= n { days.insert(d0) }
            return days.sorted()
        }

        let startDay = cal.startOfDay(for: start)
        let weekBegin0 = cal.date(byAdding: .day, value: -((wd0 - rule.weekStart + 7) % 7), to: startDay)!
        let monthBegin0 = cal.date(from: DateComponents(year: y0, month: m0, day: 1))!

        var out: [Date] = []
        var emitted = 0
        periods: for i in 0..<maxPeriods {
            let n = i * rule.interval
            var candidates: [Date] = []
            let anchor: Date
            switch rule.frequency {
            case .daily:
                anchor = cal.date(byAdding: .day, value: n, to: startDay)!
                let (y, m, d) = ymd(anchor)
                candidates = [at(y, m, d)].compactMap { $0 }
            case .weekly:
                anchor = cal.date(byAdding: .weekOfYear, value: n, to: weekBegin0)!
                let wanted = rule.byDay.isEmpty ? [wd0] : rule.byDay.map(\.weekday)
                for offset in 0..<7 {
                    let day = cal.date(byAdding: .day, value: offset, to: anchor)!
                    if wanted.contains(cal.component(.weekday, from: day)) {
                        let (y, m, d) = ymd(day)
                        if let t = at(y, m, d) { candidates.append(t) }
                    }
                }
            case .monthly:
                anchor = cal.date(byAdding: .month, value: n, to: monthBegin0)!
                let (y, m, _) = ymd(anchor)
                candidates = monthDays(y, m).compactMap { at(y, m, $0) }
            case .yearly:
                anchor = cal.date(from: DateComponents(year: y0 + n, month: 1, day: 1))!
                for m in (rule.byMonth.isEmpty ? [m0] : rule.byMonth.sorted()) {
                    candidates += monthDays(y0 + n, m).compactMap { at(y0 + n, m, $0) }
                }
            }
            if anchor > end { break }

            if rule.frequency == .daily || rule.frequency == .weekly {
                if !rule.byMonth.isEmpty {
                    candidates = candidates.filter { rule.byMonth.contains(cal.component(.month, from: $0)) }
                }
                if rule.frequency == .daily && !rule.byDay.isEmpty {
                    let wanted = rule.byDay.map(\.weekday)
                    candidates = candidates.filter { wanted.contains(cal.component(.weekday, from: $0)) }
                }
            }
            candidates.sort()
            if !rule.bySetPos.isEmpty {
                let all = candidates
                candidates = rule.bySetPos.compactMap { pos in
                    let idx = pos > 0 ? pos - 1 : all.count + pos
                    return all.indices.contains(idx) ? all[idx] : nil
                }.sorted()
            }

            for t in candidates where t >= start {
                if let until = rule.until, t > until { break periods }
                if t > end { break periods }
                out.append(t)
                emitted += 1
                if let count = rule.count, emitted >= count { break periods }
            }
        }
        return out
    }
}
