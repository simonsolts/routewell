import Foundation

public enum PresenceState: String, Sendable, Equatable, Codable {
    case online, offline, unknown
}

/// One observation: the state a refresh saw for one MAC.
public struct PresenceSample: Sendable, Equatable {
    public let mac: MACAddress
    public let at: Date
    public let state: PresenceState

    public init(mac: MACAddress, at: Date, state: PresenceState) {
        self.mac = mac
        self.at = at
        self.state = state
    }
}

/// Consecutive samples with the same state and no gap longer than the
/// continuity limit, stored as one run so a week of 30-second samples stays
/// small. `start` and `end` are the first and last sample times.
public struct PresenceRun: Sendable, Equatable, Codable {
    public var start: Date
    public var end: Date
    public var state: PresenceState
    public var observations: Int
    /// True when sampling stopped before this run (a launch, sleep, session
    /// switch, or a long gap), so the previous state does not hold until it.
    public var afterGap: Bool

    public init(start: Date, end: Date, state: PresenceState, observations: Int = 1, afterGap: Bool = false) {
        self.start = start
        self.end = end
        self.state = state
        self.observations = observations
        self.afterGap = afterGap
    }

    private enum CodingKeys: String, CodingKey { case start, end, state, observations, afterGap }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decode(Date.self, forKey: .start)
        end = try values.decode(Date.self, forKey: .end)
        state = try values.decodeIfPresent(PresenceState.self, forKey: .state) ?? .unknown
        observations = try values.decodeIfPresent(Int.self, forKey: .observations) ?? 1
        afterGap = try values.decodeIfPresent(Bool.self, forKey: .afterGap) ?? true
    }
}

/// One device's presence history, oldest run first. `open` is true while the
/// last run can still be extended: Routewell kept running and sampling since
/// it. Time not covered by a run is unknown.
public struct PresenceHistory: Sendable, Equatable, Codable {
    public var runs: [PresenceRun]
    public var open: Bool

    public init(runs: [PresenceRun] = [], open: Bool = false) {
        self.runs = runs
        self.open = open
    }

    public var observations: Int { runs.reduce(0) { $0 + $1.observations } }
    public var firstObserved: Date? { runs.first?.start }
    public var lastObserved: Date? { runs.last?.end }

    private enum CodingKeys: String, CodingKey { case runs }

    /// `open` is not saved: after a relaunch, the time the app was not
    /// running must read as unknown.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runs = try values.decodeIfPresent([PresenceRun].self, forKey: .runs) ?? []
        open = false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runs, forKey: .runs)
    }
}

/// The whole `presence.json` value.
public struct PresenceLogState: Sendable, Equatable, Codable {
    public var devices: [MACAddress: PresenceHistory]

    public init(devices: [MACAddress: PresenceHistory] = [:]) {
        self.devices = devices
    }

    private struct Entry: Codable {
        let mac: MACAddress
        let history: PresenceHistory
    }

    private enum CodingKeys: String, CodingKey { case devices }

    /// A device entry that does not decode is dropped, not the whole file.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let list = try values.decodeIfPresent([LossyEntry].self, forKey: .devices) ?? []
        devices = Dictionary(list.compactMap { $0.value.map { ($0.mac, $0.history) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Written as an array sorted by MAC so the file is stable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let list = devices.sorted { $0.key < $1.key }.map { Entry(mac: $0.key, history: $0.value) }
        try container.encode(list, forKey: .devices)
    }

    private struct LossyEntry: Decodable {
        let value: Entry?
        init(from decoder: any Decoder) throws { value = try? Entry(from: decoder) }
    }
}

/// A contiguous stretch of one state inside a display window.
public struct PresenceSegment: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let state: PresenceState

    public init(start: Date, end: Date, state: PresenceState) {
        self.start = start
        self.end = end
        self.state = state
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Pure presence arithmetic for the Availability section. A sample's state
/// holds until the next sample when that one comes within the continuity
/// limit; the open last run holds until now on the same rule. Everything
/// else is unknown, including all time Routewell was not running.
public enum PresenceTimeline {
    /// The segments that fill `window` exactly, oldest first.
    public static func segments(_ history: PresenceHistory?, window: DateInterval, now: Date, continuity: TimeInterval) -> [PresenceSegment] {
        let runs = history?.runs ?? []
        var result: [PresenceSegment] = []
        var cursor = window.start
        for (index, run) in runs.enumerated() {
            var end = run.end
            if index + 1 < runs.count {
                let next = runs[index + 1]
                if !next.afterGap, next.start.timeIntervalSince(run.end) <= continuity { end = max(end, next.start) }
            } else if history?.open == true, now.timeIntervalSince(run.end) <= continuity {
                end = max(end, now)
            }
            let start = max(run.start, cursor)
            end = min(end, window.end)
            guard end > start else { continue }
            if start > cursor { append(PresenceSegment(start: cursor, end: start, state: .unknown), to: &result) }
            append(PresenceSegment(start: start, end: end, state: run.state), to: &result)
            cursor = end
        }
        if cursor < window.end { append(PresenceSegment(start: cursor, end: window.end, state: .unknown), to: &result) }
        return result
    }

    private static func append(_ segment: PresenceSegment, to result: inout [PresenceSegment]) {
        guard segment.end > segment.start else { return }
        if let last = result.last, last.state == segment.state, last.end == segment.start {
            result[result.count - 1] = PresenceSegment(start: last.start, end: segment.end, state: last.state)
        } else {
            result.append(segment)
        }
    }

    /// Online time between local midnight and `now`.
    public static func onlineToday(_ history: PresenceHistory?, now: Date, continuity: TimeInterval, calendar: Calendar = .current) -> TimeInterval {
        let window = DateInterval(start: calendar.startOfDay(for: now), end: now)
        return segments(history, window: window, now: now, continuity: continuity)
            .filter { $0.state == .online }
            .reduce(0) { $0 + $1.duration }
    }

    public struct OnlinePeriod: Sendable, Equatable {
        public let duration: TimeInterval
        /// True when the period may have started earlier: no offline sample
        /// comes right before it.
        public let atLeast: Bool
    }

    /// The current online stretch, or `nil` when the device is not online now.
    public static func currentOnlinePeriod(_ history: PresenceHistory?, now: Date, continuity: TimeInterval) -> OnlinePeriod? {
        guard let history, history.open, let last = history.runs.last, last.state == .online,
              now.timeIntervalSince(last.end) <= continuity else { return nil }
        let previous = history.runs.count > 1 ? history.runs[history.runs.count - 2] : nil
        let proven = previous.map { $0.state == .offline && !last.afterGap && last.start.timeIntervalSince($0.end) <= continuity } ?? false
        return OnlinePeriod(duration: max(0, now.timeIntervalSince(last.start)), atLeast: !proven)
    }

    /// The last sample that saw the device offline.
    public static func lastOffline(_ history: PresenceHistory?) -> Date? {
        history?.runs.last { $0.state == .offline }?.end
    }
}
