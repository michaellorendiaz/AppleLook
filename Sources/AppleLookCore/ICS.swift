import Foundation

/// One content line of an iCalendar file: `NAME;PARAM=value:VALUE`.
public struct ICSProperty: Sendable {
    public let name: String
    public let params: [String: String]
    public let value: String
}

/// A BEGIN/END block (VCALENDAR, VEVENT, VTIMEZONE, ...).
public final class ICSComponent: @unchecked Sendable {
    public let name: String
    public internal(set) var properties: [ICSProperty] = []
    public internal(set) var children: [ICSComponent] = []

    init(name: String) { self.name = name }

    public func first(_ name: String) -> ICSProperty? { properties.first { $0.name == name } }
    public func all(_ name: String) -> [ICSProperty] { properties.filter { $0.name == name } }
    /// Unescaped text value, or "" when the property is missing.
    public func text(_ name: String) -> String { first(name).map { ICS.unescape($0.value) } ?? "" }
}

public enum ICSError: Error, LocalizedError {
    case notCalendar

    public var errorDescription: String? {
        "The link didn't return a calendar. Check that you copied the ICS link from Outlook."
    }
}

public enum ICS {
    /// Parse a whole .ics document and return its VCALENDAR.
    public static func parse(_ text: String) throws -> ICSComponent {
        var stack: [ICSComponent] = []
        var root: ICSComponent?
        for line in unfold(text) {
            guard let prop = parseLine(line) else { continue }
            switch prop.name {
            case "BEGIN":
                stack.append(ICSComponent(name: prop.value.uppercased()))
            case "END":
                guard let done = stack.popLast() else { continue }
                if let parent = stack.last {
                    parent.children.append(done)
                } else if root == nil {
                    root = done
                }
            default:
                stack.last?.properties.append(prop)
            }
        }
        guard let calendar = root, calendar.name == "VCALENDAR" else { throw ICSError.notCalendar }
        return calendar
    }

    /// Join folded lines (a line starting with a space or tab continues the previous one).
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        // "\r\n" is a single Character in Swift, so it needs its own case
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    static func parseLine(_ line: String) -> ICSProperty? {
        var inQuotes = false
        var colon: String.Index?
        for i in line.indices {
            if line[i] == "\"" {
                inQuotes.toggle()
            } else if line[i] == ":" && !inQuotes {
                colon = i
                break
            }
        }
        guard let colon else { return nil }
        var parts = splitOutsideQuotes(line[..<colon], on: ";")
        guard !parts.isEmpty else { return nil }
        let name = parts.removeFirst().uppercased()
        var params: [String: String] = [:]
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { continue }
            var value = String(part[part.index(after: eq)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            params[part[..<eq].uppercased()] = value
        }
        return ICSProperty(name: name, params: params, value: String(line[line.index(after: colon)...]))
    }

    static func splitOutsideQuotes(_ s: Substring, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for c in s {
            if c == "\"" { inQuotes.toggle() }
            if c == separator && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    public static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let next = it.next() {
                out.append(next == "n" || next == "N" ? "\n" : next)
            } else {
                out.append(c)
            }
        }
        return out
    }
}
