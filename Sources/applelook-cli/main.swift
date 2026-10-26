import AppleLookCore
import Foundation

// applelook-cli check-feed <url-or-file> [--titles] [--location] [--no-tentative]
//                          [--skip-multiday] [--label TEXT] [--keys | --dump]
// Lists what AppleLook would copy, without touching any calendar.

var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "check-feed", args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: applelook-cli check-feed <url-or-file> [--titles] [--location] [--no-tentative] [--skip-multiday] [--label TEXT] [--keys | --dump]\n".utf8))
    exit(2)
}
let source = args[1]
args = Array(args.dropFirst(2))

var options = SyncOptions()
var printKeys = false
var dump = false
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--titles": options.includeTitles = true
    case "--location": options.includeLocation = true
    case "--no-tentative": options.includeTentative = false
    case "--skip-multiday": options.skipMultidayAllDay = true
    case "--label": options.label = args.isEmpty ? "" : args.removeFirst()
    case "--keys": printKeys = true
    case "--dump": dump = true  // key, UTC start/end, title, location: for comparing with bridge.py
    default:
        FileHandle.standardError.write(Data("unknown option \(flag)\n".utf8))
        exit(2)
    }
}

let text: String
if let url = FeedURL.normalize(source) {
    let (data, _) = try await URLSession.shared.data(from: url)
    text = String(decoding: data, as: UTF8.self)
} else {
    text = try String(contentsOfFile: source, encoding: .utf8)
}

let result = Feed.desiredEvents(from: try ICS.parse(text), options: options)
let events = result.events.values.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
if printKeys {
    events.forEach { print($0.key) }
} else if dump {
    let iso = ISO8601DateFormatter()
    events.forEach { print([$0.key, iso.string(from: $0.start), iso.string(from: $0.end), $0.title, $0.location].joined(separator: "\t")) }
} else {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm"
    let dayFmt = DateFormatter()
    dayFmt.dateFormat = "yyyy-MM-dd"
    dayFmt.timeZone = TimeZone(identifier: "UTC")  // all-day events are stored as UTC midnight
    for e in events {
        let when = e.isAllDay ? "\(dayFmt.string(from: e.start)) (all day)" : fmt.string(from: e.start)
        print("\(when.padding(toLength: 28, withPad: " ", startingAt: 0)) \(e.title)\(e.location.isEmpty ? "" : "  @ \(e.location)")")
    }
    print("\n\(events.count) event(s) would be synced (\(result.feedEventCount) in feed, window -\(options.windowBackDays)/+\(options.windowForwardDays) days)")
}
for w in result.warnings { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
