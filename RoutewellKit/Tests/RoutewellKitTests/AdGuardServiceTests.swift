import Foundation
import Testing
@testable import RoutewellKit

// MARK: - Fixtures

private func fixtureJSON(_ name: String, _ subdirectory: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(subdirectory)"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

@Test func getConfigFixtureParsesBothFields() throws {
    // Recorded on 4.9.1: the whole object.
    #expect(AdGuardRouterConfig.parse(try fixtureJSON("adguardhome-get_config", "glinet/adguard")) == AdGuardRouterConfig(enabled: true, handlesDNS: true))
    // Off is `[assumed]` to keep the same two keys.
    #expect(AdGuardRouterConfig.parse(try fixtureJSON("adguardhome-get_config-off", "glinet/adguard")) == AdGuardRouterConfig(enabled: false, handlesDNS: false))
    #expect(AdGuardRouterConfig.parse(.object(["enabled": .string("1")])) == AdGuardRouterConfig())
}

// MARK: - Availability

private let at = Date(timeIntervalSince1970: 1_800_000_000)

private func reading(_ config: Result<AdGuardRouterConfig, RefreshFailureCategory>, _ answer: AdGuardServiceReading.Answer? = nil) -> AdGuardServiceReading {
    AdGuardServiceReading(config: config, answer: answer, observedAt: at)
}

@Test func availabilityFollowsConfigAndAnswer() {
    let on = AdGuardRouterConfig(enabled: true, handlesDNS: true)
    let off = AdGuardRouterConfig(enabled: false, handlesDNS: true)
    let status = AdGuardStatusResponse(version: "0.107.0", running: true)
    #expect(AdGuardAvailability.decide(nil, hasArchive: true) == .unknown)
    #expect(AdGuardAvailability.decide(reading(.success(off)), hasArchive: false) == .off)
    #expect(AdGuardAvailability.decide(reading(.success(off)), hasArchive: true) == .cached)
    #expect(AdGuardAvailability.decide(reading(.success(on), .answered(status)), hasArchive: false) == .running)
    #expect(AdGuardAvailability.decide(reading(.success(on), .answered(status)), hasArchive: true) == .running)
    #expect(AdGuardAvailability.decide(reading(.success(on), .failed(.authentication)), hasArchive: true) == .unreachable(.notAnswering(.authentication)))
    #expect(AdGuardAvailability.decide(reading(.success(on), .notConfigured), hasArchive: false) == .unreachable(.notConfigured))
    #expect(AdGuardAvailability.decide(reading(.success(on)), hasArchive: false) == .unreachable(.notAnswering(.unavailable)))
}

@Test func aFailedOrUnreadableConfigIsNeverOff() {
    for hasArchive in [false, true] {
        for category in [RefreshFailureCategory.network, .timeout, .authentication, .malformedResponse, .unavailable] {
            #expect(AdGuardAvailability.decide(reading(.failure(category)), hasArchive: hasArchive) == .unreachable(.routerUnreadable(category)))
        }
        #expect(AdGuardAvailability.decide(reading(.success(AdGuardRouterConfig())), hasArchive: hasArchive)
                == .unreachable(.routerUnreadable(.malformedResponse)))
    }
    #expect(AdGuardAvailability.running.isReadOnly == false)
    #expect(AdGuardAvailability.cached.isReadOnly)
    #expect(AdGuardAvailability.unreachable(.notConfigured).isReadOnly)
}

// MARK: - Archive store

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("routewell-archive-\(UUID())", isDirectory: true)
}

private func running(_ version: String, at date: Date, handlesDNS: Bool = true) -> AdGuardServiceReading {
    AdGuardServiceReading(config: .success(AdGuardRouterConfig(enabled: true, handlesDNS: handlesDNS)),
                          answer: .answered(AdGuardStatusResponse(version: version, running: true)), observedAt: date)
}

@Test func archiveSavesOnlyRunningReadsAndAtMostOnceAMinute() async {
    let store = AdGuardArchiveStore(root: nil)
    let profile = UUID()
    await store.save(reading(.success(AdGuardRouterConfig(enabled: false))), for: profile)
    await store.save(reading(.success(AdGuardRouterConfig(enabled: true)), .failed(.network)), for: profile)
    #expect(await store.archive(for: profile) == nil)

    await store.save(running("0.107.1", at: at), for: profile)
    await store.save(running("0.107.2", at: at.addingTimeInterval(30)), for: profile)
    var archive = await store.archive(for: profile)
    #expect(archive?.status?.value.version == "0.107.1")
    #expect(archive?.savedAt == at)

    await store.save(running("0.107.3", at: at.addingTimeInterval(30), handlesDNS: false), for: profile, force: true)
    archive = await store.archive(for: profile)
    #expect(archive?.status?.value.version == "0.107.3")
    #expect(archive?.config?.value.handlesDNS == false)

    await store.save(running("0.107.4", at: at.addingTimeInterval(91)), for: profile)
    #expect(await store.archive(for: profile)?.status?.value.version == "0.107.4")
    #expect(await store.archive(for: UUID()) == nil)
}

@Test func archivePersistsPerProfileAndIsRemovedWithIt() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = UUID()
    let other = UUID()
    let first = AdGuardArchiveStore(root: root)
    #expect(await first.save(running("0.107.1", at: at), for: profile) == nil)
    await first.save(running("0.107.9", at: at), for: other)
    let file = AdGuardArchiveStore.folder(root: root, profile: profile).appendingPathComponent("archive.json")
    #expect(FileManager.default.fileExists(atPath: file.path))

    let relaunched = AdGuardArchiveStore(root: root)
    #expect(await relaunched.archive(for: profile)?.status?.value.version == "0.107.1")
    await relaunched.remove(profile: profile)
    #expect(!FileManager.default.fileExists(atPath: AdGuardArchiveStore.folder(root: root, profile: profile).path))
    #expect(await relaunched.archive(for: profile) == nil)
    #expect(await AdGuardArchiveStore(root: root).archive(for: other)?.status?.value.version == "0.107.9")
}

@Test func aDamagedArchiveReadsAsNone() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = UUID()
    let folder = AdGuardArchiveStore.folder(root: root, profile: profile)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: folder.appendingPathComponent("archive.json"))
    let store = AdGuardArchiveStore(root: root)
    #expect(await store.archive(for: profile) == nil)
    #expect(await store.save(running("0.107.1", at: at), for: profile) == nil)
    #expect(await AdGuardArchiveStore(root: root).archive(for: profile)?.status?.value.version == "0.107.1")
}

@Test func removingTheRouterWhileASaveWaitsKeepsItRemoved() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = CommitGate()
    let store = AdGuardArchiveStore(root: root, beforeCommit: { gate.pass() })
    let profile = UUID()
    let saving = Task { await store.save(running("0.107.1", at: at), for: profile) }
    await gate.waitUntilEntered()
    await store.remove(profile: profile)
    gate.release()
    _ = await saving.value
    #expect(await store.archive(for: profile) == nil)
    #expect(!FileManager.default.fileExists(atPath: AdGuardArchiveStore.folder(root: root, profile: profile).path))
    #expect(await AdGuardArchiveStore(root: root).archive(for: profile) == nil)
}

@Test func overlappingSavesKeepEachOthersFields() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = CommitGate()
    let store = AdGuardArchiveStore(root: root, beforeCommit: { gate.pass() })
    let profile = UUID()
    var reading = AdGuardOverviewReading(range: .day, stats: .failure(.timeout), statsConfig: .failure(.timeout),
                                         protection: .failure(.timeout), filtering: .failure(.timeout), observedAt: at)
    reading.queryLog = .success(AdGuardQueryLogConfig(enabled: true, intervalMilliseconds: 86_400_000))
    let overview = Task { await store.save(reading, for: profile) }
    await gate.waitUntilEntered()
    let version = Task { await store.save(version: AdGuardVersionCheck(disabled: true), at: at, for: profile) }
    try await Task.sleep(for: .milliseconds(50))
    gate.release()
    _ = await overview.value
    _ = await version.value
    let expected = AdGuardInstanceInfo(version: AdGuardVersionCheck(disabled: true),
                                       queryLog: AdGuardQueryLogConfig(enabled: true, intervalMilliseconds: 86_400_000))
    #expect(await store.archive(for: profile)?.instance?.value == expected)
    #expect(await AdGuardArchiveStore(root: root).archive(for: profile)?.instance?.value == expected)
}

/// Holds the first file write until the test releases it.
private final class CommitGate: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private nonisolated(unsafe) var used = false
    private let lock = NSLock()

    func pass() {
        lock.lock()
        let first = !used
        used = true
        lock.unlock()
        guard first else { return }
        entered.signal()
        proceed.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func release() { proceed.signal() }
}

@Test func replaceSeedsAndClearsTheCopy() async {
    let store = AdGuardArchiveStore(root: nil)
    let profile = UUID()
    await store.replace(AdGuardArchive(status: .init(savedAt: at, value: AdGuardStatusResponse(version: "0.107.0"))), for: profile)
    #expect(await store.archive(for: profile)?.savedAt == at)
    await store.replace(nil, for: profile)
    #expect(await store.archive(for: profile) == nil)
}

// MARK: - Executor

/// Scripted router and AdGuard Home. The router keeps one config; a write
/// applies, is ignored, loses its answer, or is refused.
private actor FakeService: AdGuardServiceTransport {
    enum Write { case apply, ignore, lostThenApply, lostNoApply, errorCode(Int), errorCodeApplied(Int), invalidParameters, accessDenied }

    var config: AdGuardRouterConfig
    var answers: Bool
    /// One per write, in order; the last repeats.
    var writes: [Write]
    /// After this many config reads, every read fails.
    var configReadsLeft = Int.max
    private(set) var sent: [(enabled: Bool, handlesDNS: Bool?)] = []
    private(set) var events: [String] = []
    private(set) var statusReads = 0

    nonisolated let canReadStatus: Bool

    init(config: AdGuardRouterConfig, answers: Bool = true, writes: [Write] = [.apply], canReadStatus: Bool = true) {
        self.config = config
        self.answers = answers
        self.writes = writes
        self.canReadStatus = canReadStatus
    }

    func setConfigReadsLeft(_ count: Int) { configReadsLeft = count }
    func setAnswers(_ value: Bool) { answers = value }
    func note(_ event: String) { events.append(event) }

    func readConfig() async throws -> AdGuardRouterConfig {
        events.append("read")
        guard configReadsLeft > 0 else { throw GLiNetRPCError.transport(.timedOut) }
        configReadsLeft -= 1
        return config
    }

    func writeConfig(enabled: Bool, handlesDNS: Bool?) async throws -> Int? {
        events.append("write \(enabled)")
        sent.append((enabled, handlesDNS))
        let write = writes.count > 1 ? writes.removeFirst() : writes[0]
        let apply = {
            self.config.enabled = enabled
            if let handlesDNS { self.config.handlesDNS = handlesDNS }
        }
        switch write {
        case .apply: apply(); return nil
        case .ignore: return nil
        case .lostThenApply: apply(); throw GLiNetRPCError.transport(.timedOut)
        case .lostNoApply: throw GLiNetRPCError.transport(.timedOut)
        case .errorCode(let code): return code
        case .errorCodeApplied(let code): apply(); return code
        case .invalidParameters: throw GLiNetRPCError.invalidParameters
        case .accessDenied: throw GLiNetRPCError.accessDenied
        }
    }

    func readStatus() async throws -> AdGuardStatusResponse {
        statusReads += 1
        events.append("status")
        guard answers, config.enabled == true else { throw AdGuardClientError.transport(.timedOut) }
        return AdGuardStatusResponse(version: "0.107.0", running: true)
    }
}

private final class TestClock: Sendable {
    private nonisolated(unsafe) var date = Date(timeIntervalSince1970: 1_800_000_000)
    private let lock = NSLock()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
    func sleep(_ duration: Duration) async throws {
        advance(duration)
        try Task.checkCancellation()
    }
}

private func executor(_ service: FakeService, gate: MutationGate = MutationGate(), clock: TestClock = TestClock()) -> AdGuardServiceExecutor {
    AdGuardServiceExecutor(transport: service, gate: gate, clock: { clock.now() }, sleep: { try await clock.sleep($0) })
}

@Test func turnOnSendsTheRadioChoiceAndWaitsForAnAnswer() async {
    for handlesDNS in [true, false] {
        let service = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: !handlesDNS))
        let report = await executor(service).run(.turnOn(handlesDNS: handlesDNS), availability: .off)
        #expect(report.outcome == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: handlesDNS, answering: true)))
        #expect(report.dispatched)
        let sent = await service.sent
        #expect(sent.count == 1 && sent[0].enabled && sent[0].handlesDNS == handlesDNS)
    }
}

@Test func turnOnFromTheCachedCopyIsAllowedButNotWhileRunningOrUnreachable() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true))
    #expect(await executor(service).run(.turnOn(handlesDNS: true), availability: .cached).outcome
            == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: true, answering: true)))
    for availability in [AdGuardAvailability.running, .unknown, .unreachable(.notConfigured)] {
        let untouched = FakeService(config: AdGuardRouterConfig(enabled: false))
        let report = await executor(untouched).run(.turnOn(handlesDNS: true), availability: availability)
        guard case .rejected = report.outcome else { Issue.record("expected rejection"); continue }
        #expect(!report.dispatched)
        #expect(await untouched.events.isEmpty)
    }
}

@Test func writesOtherThanTurnOnAreRejectedBeforeAnyReadWhenNotRunning() async {
    for intent in [AdGuardServiceIntent.turnOff, .restart, .setHandlesDNS(false)] {
        for availability in [AdGuardAvailability.cached, .off, .unreachable(.notAnswering(.timeout)), .unknown] {
            let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true))
            let report = await executor(service).run(intent, availability: availability)
            #expect(report.outcome == .rejected(.preconditionFailed("AdGuard Home is not running.")))
            #expect(await service.events.isEmpty)
        }
    }
}

@Test func turnOnThatTheRouterRefusesWithAnErrorCodeIsAMismatch() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true), writes: [.errorCode(2)])
    let report = await executor(service).run(.turnOn(handlesDNS: true), availability: .off)
    #expect(report.outcome == .verifiedMismatch(expected: AdGuardServiceState(enabled: true, handlesDNS: true, answering: true),
                                               actual: AdGuardServiceState(enabled: false, handlesDNS: true)))
    #expect(report.dispatched)
    #expect(await service.sent.count == 1)
}

@Test func errorCodeOneSaysAnotherDNSSettingIsOn() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true), writes: [.errorCode(1)])
    let report = await executor(service).run(.turnOn(handlesDNS: true), availability: .off)
    #expect(report.outcome == .rejected(.preconditionFailed(AdGuardServiceExecutor.otherDNSMessage)))
    #expect(report.dispatched)
}

@Test func anErrorCodeWithTheChangeAppliedIsVerifiedAsUsual() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true), writes: [.errorCodeApplied(1)])
    #expect(await executor(service).run(.turnOn(handlesDNS: true), availability: .off).outcome
            == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: true, answering: true)))
    #expect(await service.sent.count == 1)
}

@Test func withoutAnAdGuardConnectionTheRouterSettingDecides() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true), canReadStatus: false)
    let report = await executor(service).run(.turnOn(handlesDNS: true), availability: .off)
    #expect(report.outcome == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: true)))
    #expect(await service.statusReads == 0)

    let stop = await executor(service).run(.turnOff, availability: .running) { reading in
        #expect(reading.answer == .notConfigured)
    }
    #expect(stop.outcome == .verifiedSuccess(AdGuardServiceState(enabled: false, handlesDNS: true)))
    #expect(await service.statusReads == 0)
}

@Test func restartStopsWhenTheRouterRefusesOffAndCannotBeRead() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true), writes: [.errorCode(2)])
    await service.setConfigReadsLeft(1)
    let report = await executor(service).run(.restart, availability: .running)
    #expect(report.outcome == .unknownAfterDispatch)
    // A router that refused "off" is not sent "on".
    #expect(await service.sent.map(\.enabled) == [false])
}

@Test func turnOnWhoseServiceNeverAnswersIsAMismatch() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true), answers: false)
    let report = await executor(service).run(.turnOn(handlesDNS: true), availability: .off)
    #expect(report.outcome == .verifiedMismatch(expected: AdGuardServiceState(enabled: true, handlesDNS: true, answering: true),
                                               actual: AdGuardServiceState(enabled: true, handlesDNS: true, answering: false)))
    #expect(report.failure == .timeout)
    #expect(await service.statusReads > 10)
}

@Test func aLostAnswerIsVerifiedNotResent() async {
    let applied = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true), writes: [.lostThenApply])
    #expect(await executor(applied).run(.turnOn(handlesDNS: true), availability: .off).outcome
            == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: true, answering: true)))
    #expect(await applied.sent.count == 1)

    // The write may have applied, but the router never answers again.
    let silent = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true), writes: [.lostNoApply])
    await silent.setConfigReadsLeft(1)
    let report = await executor(silent).run(.turnOn(handlesDNS: true), availability: .off)
    #expect(report.outcome == .unknownAfterDispatch)
    #expect(report.dispatched)
    #expect(await silent.sent.count == 1)
}

@Test func refusedOrInvalidWritesAreRejectedAfterDispatch() async {
    let invalid = FakeService(config: AdGuardRouterConfig(enabled: false, handlesDNS: true), writes: [.invalidParameters])
    let report = await executor(invalid).run(.turnOn(handlesDNS: true), availability: .off)
    #expect(report.outcome == .rejected(.preconditionFailed("The router did not accept the settings Routewell sent.")))
    #expect(report.dispatched)

    let denied = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true), writes: [.accessDenied])
    #expect(await executor(denied).run(.turnOff, availability: .running).failure == .authentication)
}

@Test func aFailedBeforeReadSendsNothing() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true))
    await service.setConfigReadsLeft(0)
    let report = await executor(service).run(.turnOff, availability: .running)
    #expect(report.outcome == .rejected(.preconditionFailed("The router did not say whether AdGuard Home is on.")))
    #expect(!report.dispatched)
    #expect(await service.sent.isEmpty)
}

@Test func stopSyncsFirstThenTurnsOffAndKeepsHandleDNS() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: false))
    let report = await executor(service).run(.turnOff, availability: .running) { reading in
        #expect(reading.status?.version == "0.107.0")
        #expect(reading.config == .success(AdGuardRouterConfig(enabled: true, handlesDNS: false)))
        await service.note("sync")
    }
    #expect(report.outcome == .verifiedSuccess(AdGuardServiceState(enabled: false, handlesDNS: false)))
    let events = await service.events
    #expect(events.prefix(4) == ["read", "status", "sync", "write false"])
    let sent = await service.sent
    #expect(sent.count == 1 && sent[0].handlesDNS == false)
}

@Test func stopThatTheRouterIgnoresReportsTheRouterState() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true), writes: [.ignore])
    let report = await executor(service).run(.turnOff, availability: .running)
    #expect(report.outcome == .verifiedMismatch(expected: AdGuardServiceState(enabled: false, handlesDNS: true),
                                               actual: AdGuardServiceState(enabled: true, handlesDNS: true)))
    #expect(await service.sent.count == 1)
}

@Test func handleDNSChangesOnlyThatSetting() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true))
    #expect(await executor(service).run(.setHandlesDNS(false), availability: .running).outcome
            == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: false)))
    let sent = await service.sent
    #expect(sent.count == 1 && sent[0].enabled && sent[0].handlesDNS == false)

    // Already set: nothing is sent.
    let report = await executor(service).run(.setHandlesDNS(false), availability: .running)
    #expect(report.outcome == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: false)))
    #expect(!report.dispatched)
    #expect(await service.sent.count == 1)
}

@Test func restartTurnsOffThenOnAndWaitsForAnAnswer() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: false))
    let report = await executor(service).run(.restart, availability: .running)
    #expect(report.outcome == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: false, answering: true)))
    let sent = await service.sent
    #expect(sent.map(\.enabled) == [false, true])
    #expect(sent.allSatisfy { $0.handlesDNS == false })
}

@Test func restartThatLosesTheRouterAfterDispatchIsUnknown() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true), writes: [.lostThenApply, .lostNoApply])
    // The before-read works; every later read fails.
    await service.setConfigReadsLeft(1)
    let report = await executor(service).run(.restart, availability: .running)
    #expect(report.outcome == .unknownAfterDispatch)
    #expect(report.dispatched)
    #expect(await service.sent.map(\.enabled) == [false, true])
}

@Test func restartStopsWhenTheRouterKeepsAdGuardHomeOn() async {
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true), writes: [.ignore])
    let report = await executor(service).run(.restart, availability: .running)
    guard case .verifiedMismatch = report.outcome else { Issue.record("expected mismatch"); return }
    #expect(await service.sent.map(\.enabled) == [false])
}

@Test func serviceWritesShareTheGate() async throws {
    let gate = MutationGate()
    let token = try await gate.acquire()
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true))
    let waiting = Task { await executor(service, gate: gate).run(.setHandlesDNS(false), availability: .running) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await service.events.isEmpty)
    await gate.release(token)
    #expect(await waiting.value.outcome == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: false)))
}

@Test func cancelledWhileQueuedSendsNothing() async throws {
    let gate = MutationGate()
    let token = try await gate.acquire()
    let service = FakeService(config: AdGuardRouterConfig(enabled: true, handlesDNS: true))
    let waiting = Task { await executor(service, gate: gate).run(.turnOff, availability: .running) }
    try await Task.sleep(for: .milliseconds(20))
    waiting.cancel()
    let report = await waiting.value
    await gate.release(token)
    #expect(report.outcome == .rejected(.preconditionFailed("Cancelled before dispatch")))
    #expect(await service.events.isEmpty)
}

@Test func setConfigReplyErrorCodeIsRead() {
    #expect(LiveAdGuardServiceTransport.errorCode(.null) == nil)
    #expect(LiveAdGuardServiceTransport.errorCode(.object([:])) == nil)
    #expect(LiveAdGuardServiceTransport.errorCode(.object(["err_code": .number(0)])) == nil)
    #expect(LiveAdGuardServiceTransport.errorCode(.object(["err_code": .number(1), "err_msg": .string("Other DNS not closed")])) == 1)
}
