import Foundation

/// A DTSTART/DTEND/EXDATE/RECURRENCE-ID value.
public struct ICSDate: Sendable, Equatable {
    /// The instant. All-day dates are midnight UTC of that day, as in bridge.py.
    public let date: Date
    public let isAllDay: Bool
    /// The zone the value was written in; recurrences are expanded in it.
    public let timeZone: TimeZone
}

public let utc = TimeZone(identifier: "UTC")!

/// Parses date values, resolving TZIDs (including Outlook's Windows zone names).
/// Remembers TZIDs it couldn't resolve so they can be reported.
public final class ICSDateParser {
    private var zoneCache: [String: TimeZone] = [:]
    public private(set) var unknownZones: Set<String> = []

    public init() {}

    public func parse(_ prop: ICSProperty) -> ICSDate? {
        parse(prop.value, tzid: prop.params["TZID"], isDate: prop.params["VALUE"]?.uppercased() == "DATE")
    }

    /// All values of a multi-valued property (EXDATE can hold a comma-separated list).
    public func parseList(_ prop: ICSProperty) -> [ICSDate] {
        prop.value.split(separator: ",").compactMap {
            parse(String($0), tzid: prop.params["TZID"], isDate: prop.params["VALUE"]?.uppercased() == "DATE")
        }
    }

    public func parse(_ raw: String, tzid: String?, isDate: Bool = false, defaultZone: TimeZone = utc) -> ICSDate? {
        let v = Array(raw.trimmingCharacters(in: .whitespaces).utf8)
        func num(_ r: Range<Int>) -> Int? {
            guard r.upperBound <= v.count else { return nil }
            return Int(String(decoding: v[r], as: UTF8.self))
        }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8) else { return nil }
        if v.count == 8 || isDate {
            guard let date = makeDate(y, mo, d, 0, 0, 0, in: utc) else { return nil }
            return ICSDate(date: date, isAllDay: true, timeZone: utc)
        }
        guard v.count >= 15, v[8] == UInt8(ascii: "T"),
              let h = num(9..<11), let mi = num(11..<13), let s = num(13..<15) else { return nil }
        let zone: TimeZone
        if v.last == UInt8(ascii: "Z") {
            zone = utc
        } else if let tzid {
            zone = resolve(tzid)
        } else {
            zone = defaultZone  // floating time; bridge.py treats it as UTC
        }
        guard let date = makeDate(y, mo, d, h, mi, s, in: zone) else { return nil }
        return ICSDate(date: date, isAllDay: false, timeZone: zone)
    }

    func resolve(_ tzid: String) -> TimeZone {
        if let cached = zoneCache[tzid] { return cached }
        let zone: TimeZone
        if let z = TimeZones.zone(for: tzid) {
            zone = z
        } else {
            unknownZones.insert(tzid)
            zone = .current
        }
        zoneCache[tzid] = zone
        return zone
    }
}

func makeDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, in zone: TimeZone) -> Date? {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))
}

/// Parse an iCalendar DURATION such as PT1H30M, P1D or -PT15M.
func parseDuration(_ s: String) -> TimeInterval? {
    var sign = 1.0
    var rest = Substring(s.trimmingCharacters(in: .whitespaces))
    if rest.first == "-" { sign = -1; rest = rest.dropFirst() } else if rest.first == "+" { rest = rest.dropFirst() }
    guard rest.first == "P" else { return nil }
    rest = rest.dropFirst()
    var total = 0.0
    var number = ""
    for c in rest {
        if c.isNumber { number.append(c); continue }
        if c == "T" { continue }
        guard let n = Double(number) else { return nil }
        switch c {
        case "W": total += n * 7 * 86400
        case "D": total += n * 86400
        case "H": total += n * 3600
        case "M": total += n * 60
        case "S": total += n
        default: return nil
        }
        number = ""
    }
    return sign * total
}
