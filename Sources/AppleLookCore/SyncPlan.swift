import Foundation

/// An event AppleLook created earlier, as read back from the calendar.
public struct ExistingEvent: Equatable, Sendable {
    public let key: String
    public let start: Date
    public let end: Date
    public let title: String
    public let location: String

    public init(key: String, start: Date, end: Date, title: String, location: String) {
        self.key = key
        self.start = start
        self.end = end
        self.title = title
        self.location = location
    }
}

/// What a sync needs to do to make the calendar match the feed.
public struct SyncPlan: Equatable, Sendable {
    public var creates: [DesiredEvent] = []
    public var updates: [DesiredEvent] = []
    public var deletes: [String] = []

    public var isEmpty: Bool { creates.isEmpty && updates.isEmpty && deletes.isEmpty }

    public init(desired: [String: DesiredEvent], existing: [String: ExistingEvent]) {
        for key in desired.keys.sorted() {
            let want = desired[key]!
            guard let have = existing[key] else {
                creates.append(want)
                continue
            }
            if abs(have.start.timeIntervalSince(want.start)) >= 1
                || abs(have.end.timeIntervalSince(want.end)) >= 1
                || have.title != want.title
                || have.location != want.location {
                updates.append(want)
            }
        }
        deletes = existing.keys.filter { desired[$0] == nil }.sorted()
    }
}
