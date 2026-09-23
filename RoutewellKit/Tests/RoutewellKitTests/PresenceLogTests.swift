import Foundation
import Testing
@testable import RoutewellKit

private let phone = mac("66:29:ea:33:fb:78")
private let printer = mac("3c:52:82:7a:0d:91")
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

@Suite struct PresenceLogTests {
    private func temporaryStore() -> (AtomicJSONStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (AtomicJSONStore(directory: directory), directory)
    }

    @Test func oneSamplePerRefreshExtendsARunOfEqualState() async {
        let log = PresenceLog(store: nil)
        for step in 0..<10 { await log.record([phone: .online], at: t0.addingTimeInterval(Double(step) * 30)) }
        let history = await log.history(for: phone)
        #expect(history?.runs == [PresenceRun(start: t0, end: t0.addingTimeInterval(270), state: .online, observations: 10, afterGap: true)])
        #expect(history?.observations == 10)
        #expect(history?.open == true)
    }

    @Test func aStateChangeStartsANewRun() async {
        let log = PresenceLog(store: nil)
        await log.record([phone: .online], at: t0)
        await log.record([phone: .offline], at: t0.addingTimeInterval(30))
        await log.record([phone: .unknown], at: t0.addingTimeInterval(60))
        #expect(await log.history(for: phone)?.runs.map(\.state) == [.online, .offline, .unknown])
    }

    @Test func aGapLongerThanTheContinuityLimitIsUnknown() async {
        let log = PresenceLog(store: nil)
        await log.record([phone: .online], at: t0)
        await log.record([phone: .online], at: t0.addingTimeInterval(30))
        let later = t0.addingTimeInterval(30 + PresenceLog.continuity + 1)
        await log.record([phone: .online], at: later)
        let history = await log.history(for: phone)
        #expect(history?.runs.count == 2)
        let segments = PresenceTimeline.segments(history, window: DateInterval(start: t0, end: later), now: later, continuity: PresenceLog.continuity)
        #expect(segments.map(\.state) == [.online, .unknown])
        #expect(segments[0].end == t0.addingTimeInterval(30))
    }

    @Test func timeTheAppWasNotRunningIsUnknown() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PresenceLog(store: store)
        await first.record([phone: .online], at: t0)
        await first.record([phone: .online], at: t0.addingTimeInterval(30))
        #expect(await first.flush(at: t0.addingTimeInterval(30)) == nil)

        // A relaunch 60 s later: the gap is inside the continuity limit, but
        // nothing sampled it, so it must not read as online.
        let relaunched = PresenceLog(store: AtomicJSONStore(directory: directory))
        #expect(await relaunched.load() == .loaded)
        #expect(await relaunched.history(for: phone)?.open == false)
        let now = t0.addingTimeInterval(90)
        await relaunched.record([phone: .online], at: now)
        let history = await relaunched.history(for: phone)
        #expect(history?.runs.count == 2)
        let segments = PresenceTimeline.segments(history, window: DateInterval(start: t0, end: now), now: now, continuity: PresenceLog.continuity)
        #expect(segments.map(\.state) == [.online, .unknown])
    }

    @Test func interruptionBreaksTheRun() async {
        let log = PresenceLog(store: nil)
        await log.record([phone: .online], at: t0)
        await log.interrupt()
        await log.record([phone: .online], at: t0.addingTimeInterval(30))
        #expect(await log.history(for: phone)?.runs.count == 2)
    }

    @Test func aDeviceNoLongerSampledIsClosed() async {
        let log = PresenceLog(store: nil)
        await log.record([phone: .online, printer: .online], at: t0)
        await log.record([phone: .online], at: t0.addingTimeInterval(30))
        #expect(await log.history(for: printer)?.open == false)
        let now = t0.addingTimeInterval(60)
        let segments = PresenceTimeline.segments(await log.history(for: printer), window: DateInterval(start: t0, end: now), now: now, continuity: PresenceLog.continuity)
        #expect(segments.map(\.state) == [.unknown])
    }

    @Test func retentionDropsRunsOlderThanSevenDays() async {
        let log = PresenceLog(store: nil)
        await log.record([phone: .offline, printer: .online], at: t0)
        await log.record([phone: .online], at: t0.addingTimeInterval(3_600))
        await log.record([phone: .online], at: t0.addingTimeInterval(PresenceLog.retention + 60))
        let history = await log.history(for: phone)
        #expect(history?.runs.map(\.state) == [.online, .online])
        #expect(history?.runs.first.map { $0.start >= t0.addingTimeInterval(60) } == true)
        #expect(await log.history(for: printer) == nil)
    }

    @Test func sizeIsBoundedPerDeviceAndInDeviceCount() async {
        let log = PresenceLog(store: nil)
        var time = t0
        for index in 0..<(PresenceLog.maxRunsPerDevice + 10) {
            await log.record([phone: index.isMultiple(of: 2) ? .online : .offline], at: time)
            time += 30
        }
        #expect(await log.history(for: phone)?.runs.count == PresenceLog.maxRunsPerDevice)

        var many: [MACAddress: PresenceState] = [:]
        for index in 0..<(PresenceLog.maxDevices + 5) {
            many[MACAddress(String(format: "02%010X", index))!] = .online
        }
        await log.record(many, at: time)
        #expect(await log.snapshot().devices.count == PresenceLog.maxDevices)
    }

    @Test func extensionsSaveAtMostEveryIntervalAndChangesSaveAtOnce() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = PresenceLog(store: store, extensionSaveInterval: 300)
        func onDisk() async throws -> PresenceHistory? {
            try await AtomicJSONStore(directory: directory).load(PresenceLogState.self, from: .presence)?.devices[phone]
        }
        await log.record([phone: .online], at: t0)
        #expect(try await onDisk()?.observations == 1)
        await log.record([phone: .online], at: t0.addingTimeInterval(30))
        #expect(try await onDisk()?.observations == 1)
        await log.record([phone: .offline], at: t0.addingTimeInterval(60))
        #expect(try await onDisk()?.runs.count == 2)
    }

    @Test func clearHistoryRemovesOnlyThatDevice() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = PresenceLog(store: store)
        await log.record([phone: .online, printer: .offline], at: t0)
        let report = await log.clearHistory(phone, at: t0.addingTimeInterval(1))
        #expect(report.outcome == .verifiedSuccess(phone))
        #expect(await log.history(for: phone) == nil)
        #expect(await log.history(for: printer) != nil)
        let saved = try await AtomicJSONStore(directory: directory).load(PresenceLogState.self, from: .presence)
        #expect(saved?.devices[phone] == nil)
        #expect(saved?.devices[printer] != nil)
    }

    @Test func aFailedClearKeepsTheHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = PresenceLog(store: AtomicJSONStore(directory: directory, beforeCommit: { throw CocoaError(.fileWriteUnknown) }))
        await log.record([phone: .online], at: t0)
        let report = await log.clearHistory(phone, at: t0)
        #expect(report.outcome == .unknownAfterDispatch)
        #expect(await log.history(for: phone) != nil)
    }

    @Test func samplesMarkUnlistedKnownDevicesOffline() {
        let samples = PresenceLog.samples(listed: [phone: .value(true), printer: .unknown], known: [phone, mac("9c:f4:8e:31:77:b2")])
        #expect(samples == [phone: .online, printer: .unknown, mac("9c:f4:8e:31:77:b2"): .offline])
    }

    @Test func overviewClientListCarriesOnlineFlags() throws {
        let list = try clientFixture("clients-get_list-4.9.1", "glinet/clients")
        let status = GLiNetStatusParser.clientStatus(getStatus: nil, clientList: list)
        let listed = try #require(status.listed)
        #expect(listed.count == list["clients"]?.array?.count)
        #expect(status.activeCount == .value(listed.values.filter { $0 == .value(true) }.count))
        #expect(GLiNetStatusParser.clientStatus(getStatus: .object([:]), clientList: nil).listed == nil)
    }

    @Test func decodingDropsOnlyADamagedDevice() throws {
        let json = #"{"devices":[{"mac":"662 9EA33FB78","history":{"runs":[]}},{"mac":"3C52827A0D91","history":{"runs":[{"start":0,"end":30,"state":"online","observations":2}]}}]}"#
        let state = try JSONDecoder().decode(PresenceLogState.self, from: Data(json.utf8))
        #expect(state.devices.count == 1)
        #expect(state.devices[printer]?.observations == 2)
    }
}

@Suite struct PresenceTimelineTests {
    private let continuity = PresenceLog.continuity

    @Test func aStateHoldsUntilTheNextSampleAndTheOpenRunUntilNow() {
        let history = PresenceHistory(runs: [
            PresenceRun(start: t0, end: t0.addingTimeInterval(60), state: .offline),
            PresenceRun(start: t0.addingTimeInterval(90), end: t0.addingTimeInterval(300), state: .online),
        ], open: true)
        let now = t0.addingTimeInterval(330)
        let afterRelaunch = PresenceHistory(runs: [history.runs[0], PresenceRun(start: t0.addingTimeInterval(90), end: t0.addingTimeInterval(300), state: .online, afterGap: true)], open: true)
        #expect(PresenceTimeline.segments(afterRelaunch, window: DateInterval(start: t0, end: now), now: now, continuity: continuity).map(\.state) == [.offline, .unknown, .online])
        let segments = PresenceTimeline.segments(history, window: DateInterval(start: t0.addingTimeInterval(-60), end: now), now: now, continuity: continuity)
        #expect(segments == [
            PresenceSegment(start: t0.addingTimeInterval(-60), end: t0, state: .unknown),
            PresenceSegment(start: t0, end: t0.addingTimeInterval(90), state: .offline),
            PresenceSegment(start: t0.addingTimeInterval(90), end: now, state: .online),
        ])
    }

    @Test func aClosedOrStaleRunDoesNotReachNow() {
        let run = PresenceRun(start: t0, end: t0.addingTimeInterval(60), state: .online)
        let now = t0.addingTimeInterval(120)
        let window = DateInterval(start: t0, end: now)
        let closed = PresenceTimeline.segments(PresenceHistory(runs: [run], open: false), window: window, now: now, continuity: continuity)
        #expect(closed.last == PresenceSegment(start: t0.addingTimeInterval(60), end: now, state: .unknown))
        let late = t0.addingTimeInterval(60 + continuity + 1)
        let stale = PresenceTimeline.segments(PresenceHistory(runs: [run], open: true), window: DateInterval(start: t0, end: late), now: late, continuity: continuity)
        #expect(stale.last?.state == .unknown)
    }

    @Test func onlineTodayCountsOnlyTodaysOnlineTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.startOfDay(for: t0)
        let history = PresenceHistory(runs: [
            PresenceRun(start: midnight.addingTimeInterval(-3_600), end: midnight.addingTimeInterval(600), state: .online),
            PresenceRun(start: midnight.addingTimeInterval(700), end: midnight.addingTimeInterval(1_000), state: .offline),
        ], open: true)
        let now = midnight.addingTimeInterval(1_000)
        #expect(PresenceTimeline.onlineToday(history, now: now, continuity: continuity, calendar: calendar) == 700)
    }

    @Test func currentOnlinePeriodIsExactOnlyAfterAnOfflineSample() {
        let now = t0.addingTimeInterval(400)
        let afterOffline = PresenceHistory(runs: [
            PresenceRun(start: t0, end: t0.addingTimeInterval(60), state: .offline),
            PresenceRun(start: t0.addingTimeInterval(90), end: t0.addingTimeInterval(390), state: .online),
        ], open: true)
        #expect(PresenceTimeline.currentOnlinePeriod(afterOffline, now: now, continuity: continuity) == .init(duration: 310, atLeast: false))
        let afterGap = PresenceHistory(runs: [PresenceRun(start: t0.addingTimeInterval(90), end: t0.addingTimeInterval(390), state: .online, afterGap: true)], open: true)
        #expect(PresenceTimeline.currentOnlinePeriod(afterGap, now: now, continuity: continuity) == .init(duration: 310, atLeast: true))
        let offlineNow = PresenceHistory(runs: [PresenceRun(start: t0, end: t0.addingTimeInterval(390), state: .offline)], open: true)
        #expect(PresenceTimeline.currentOnlinePeriod(offlineNow, now: now, continuity: continuity) == nil)
        #expect(PresenceTimeline.lastOffline(afterOffline) == t0.addingTimeInterval(60))
        #expect(PresenceTimeline.lastOffline(afterGap) == nil)
    }
}
