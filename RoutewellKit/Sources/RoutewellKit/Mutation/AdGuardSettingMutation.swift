import Foundation

/// What the caller wants AdGuard's protection setting to become.
public enum ProtectionIntent: Sendable, Equatable {
    case enable
    case disable
    /// More than 0 and at most 48 hours: the Pause menu runs from 30
    /// seconds to "until tomorrow" at 08:00 (at most 32 hours).
    case pause(Duration)

    /// The exact wire shape for `POST control/protection`.
    public var wire: (enabled: Bool, durationMilliseconds: Int) {
        switch self {
        case .enable:
            return (true, 0)
        case .disable:
            return (false, 0)
        case .pause(let duration):
            return (false, Self.milliseconds(from: duration))
        }
    }

    public func validate() -> MutationRejection? {
        switch self {
        case .enable, .disable:
            return nil
        case .pause(let duration):
            if Self.milliseconds(from: duration) <= 0 || duration > .seconds(48 * 60 * 60) {
                return .invalidIntent("Pause duration must be more than 0 and at most 48 hours")
            }
            return nil
        }
    }

    static func milliseconds(from duration: Duration) -> Int {
        let components = duration.components
        let fromSeconds = components.seconds * 1000
        let fromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(fromSeconds + fromAttoseconds)
    }
}

/// A change to a setting inside AdGuard Home (architecture 04): protection
/// on, off, or paused, "Filter requests", the three Protection switches,
/// lists and rules, and DNS settings.
public enum AdGuardSettingIntent: Sendable, Equatable {
    case protection(ProtectionIntent)
    /// AdGuard Home's "Filter requests": blocklists, allowlists, and rules.
    case filtering(enabled: Bool)
    case feature(AdGuardFeature, enabled: Bool)
    /// Block Domain or Unblock Domain from the Query Log (chunk 18): one
    /// rule in the custom rules.
    case domainRule(DomainRuleAction, domain: String)
    // Lists are found by URL.
    /// Turn one list on or off (`set_url`, name and URL as read).
    case listEnabled(FilterListKind, url: String, enabled: Bool)
    case addList(FilterListKind, name: String, url: String)
    case removeList(FilterListKind, url: String)
    /// "Check every", in hours; `enabled` goes back as read.
    case updateInterval(hours: Int)
    /// Update Now for one list kind.
    case updateLists(FilterListKind)
    /// Save the custom rules. `loaded` is what the editor started from:
    /// when AdGuard Home's rules are no longer that, nothing is sent.
    case saveRules([String], loaded: [String])
    /// DNS Apply: only the fields that changed (`dns_config`).
    case dns(changes: [String: JSONValue])
    case clearDNSCache

    /// Writes run only while AdGuard Home runs; the read-only UI is not the
    /// only guard.
    public func validate(_ availability: AdGuardAvailability) -> MutationRejection? {
        guard availability == .running else { return .preconditionFailed("AdGuard Home is not running.") }
        switch self {
        case .protection(let intent): return intent.validate()
        case .domainRule(let action, let domain):
            return action.rule(for: domain) == nil ? .invalidIntent("Not a domain name") : nil
        case .addList(_, let name, let url):
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .invalidIntent("Enter a name for the list.") }
            return FilterListURL.validated(url) == nil ? .invalidIntent("Enter a URL that starts with http:// or https://.") : nil
        case .updateInterval(let hours):
            return FilterUpdateInterval.isValid(hours) ? nil : .invalidIntent("Not a check interval")
        case .dns(let changes):
            return changes.isEmpty ? .invalidIntent("No DNS changes") : nil
        case .filtering, .feature, .listEnabled, .removeList, .updateLists, .saveRules, .clearDNSCache: return nil
        }
    }
}

/// What AdGuard Home reported after a setting write.
public enum AdGuardSettingState: Sendable, Equatable {
    case protection(ProtectionState)
    /// A switch; `nil` when the status did not say.
    case feature(Bool?)
    /// The domain rule is in the custom rules, and its opposite is not.
    case rule(applied: Bool)
    case filters(AdGuardFilteringStatus)
    /// Update Now: AdGuard Home's `updated` count (`nil` when it sent
    /// none), and the lists after it.
    case listsUpdated(Int?, AdGuardFilteringStatus?)
    /// The custom rules AdGuard Home reported.
    case rules([String])
    case dns(AdGuardDNSSettings)
    case cacheCleared
}

/// The calls a setting write needs. Live: AdGuard Home's own API.
public protocol AdGuardSettingTransport: Sendable {
    func readStatus() async throws -> AdGuardStatusResponse
    /// The feature's status object as AdGuard Home sent it (`enabled`, and
    /// for Safe Search the engine flags).
    func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue
    /// `control/filtering/status`.
    func readFiltering() async throws -> AdGuardFilteringStatus
    /// `control/filtering/status` `user_rules`, as sent.
    func readUserRules() async throws -> [String]
    func write(_ write: AdGuardWrite) async throws
    /// `POST control/filtering/refresh`: the `updated` count, or `nil`
    /// when the reply has none.
    func refreshLists(_ kind: FilterListKind) async throws -> Int?
    /// `control/dns_info`.
    func readDNS() async throws -> AdGuardDNSSettings
    /// `POST control/test_upstream_dns`: the reply as sent.
    func testUpstreams(_ request: UpstreamTestRequest) async throws -> JSONValue?
}

public extension AdGuardSettingTransport {
    func readDNS() async throws -> AdGuardDNSSettings { throw AdGuardClientError.malformedResponse }
    func testUpstreams(_ request: UpstreamTestRequest) async throws -> JSONValue? { throw AdGuardClientError.malformedResponse }

    func refreshLists(_ kind: FilterListKind) async throws -> Int? {
        try await write(.refreshLists(whitelist: kind.isAllowlist))
        return nil
    }
}

/// Runs one setting write. `nil` from `RouterBackend.adGuardSettings` means
/// the profile has no AdGuard Home connection.
public protocol AdGuardSettingControl: Sendable {
    func run(_ intent: AdGuardSettingIntent, availability: AdGuardAvailability) async -> MutationReport<AdGuardSettingState>
    /// Test Upstreams: a check, not a change, so it does not wait for the
    /// gate. Only while AdGuard Home runs.
    func testUpstreams(_ request: UpstreamTestRequest, availability: AdGuardAvailability) async -> Result<UpstreamTestResult, RefreshFailureCategory>
}

public extension AdGuardSettingControl {
    func testUpstreams(_ request: UpstreamTestRequest, availability: AdGuardAvailability) async -> Result<UpstreamTestResult, RefreshFailureCategory> {
        .failure(.unavailable)
    }
}

/// Timing knobs for verifying a setting write. All virtual-clock driven
/// so tests never wait in real time.
public struct AdGuardSettingVerifyPolicy: Sendable, Equatable {
    public var deadline: Duration = .seconds(8)
    public var pollInterval: Duration = .milliseconds(500)
    /// The observed remaining pause may be shorter than requested by up to
    /// this much (time passes between dispatch and read-back).
    public var pauseTolerance: Duration = .seconds(30)

    public init() {}
}

/// Gate → availability check → before-state (a fresh read of only the
/// setting) → dispatch once → bounded verify. Every setting write is
/// `resync`: a mismatch reports what AdGuard Home says and nothing is sent
/// again. Generalised from chunk 10's `ProtectionMutationExecutor`, which
/// sent the old state back after a mismatch.
public struct AdGuardSettingExecutor: AdGuardSettingControl {
    private let transport: any AdGuardSettingTransport
    private let gate: MutationGate
    private let policy: AdGuardSettingVerifyPolicy
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: SessionEventLog?

    public init(
        transport: any AdGuardSettingTransport,
        gate: MutationGate,
        policy: AdGuardSettingVerifyPolicy = .init(),
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: SessionEventLog? = nil
    ) {
        self.transport = transport
        self.gate = gate
        self.policy = policy
        self.clock = clock
        self.sleep = sleep
        self.log = log
    }

    private typealias Step = (outcome: MutationOutcome<AdGuardSettingState>, dispatched: Bool, failure: RefreshFailureCategory?)

    public func run(_ intent: AdGuardSettingIntent, availability: AdGuardAvailability) async -> MutationReport<AdGuardSettingState> {
        let startedAt = clock()
        if let rejection = intent.validate(availability) {
            return report((.rejected(rejection), false, nil), startedAt: startedAt)
        }
        let token: MutationGateToken
        do {
            token = try await gate.acquire()
        } catch {
            // A cancelled waiter never acquires the gate, so there is
            // nothing to release here.
            return report((.rejected(.preconditionFailed("Cancelled before dispatch")), false, nil), startedAt: startedAt)
        }
        if Task.isCancelled {
            await gate.release(token)
            return report((.rejected(.preconditionFailed("Cancelled before dispatch")), false, nil), startedAt: startedAt)
        }
        let step: Step
        switch intent {
        case .protection(let protection): step = await performProtection(protection)
        case .filtering(let enabled): step = await performFiltering(enabled: enabled)
        case .feature(let feature, let enabled): step = await performFeature(feature, enabled: enabled)
        case .domainRule(let action, let domain): step = await performDomainRule(action, domain: domain)
        case .listEnabled(let kind, let url, let enabled): step = await performListEnabled(kind, url: url, enabled: enabled)
        case .addList(let kind, let name, let url): step = await performAddList(kind, name: name, url: url)
        case .removeList(let kind, let url): step = await performRemoveList(kind, url: url)
        case .updateInterval(let hours): step = await performInterval(hours: hours)
        case .updateLists(let kind): step = await performUpdateLists(kind)
        case .saveRules(let rules, let loaded): step = await performSaveRules(rules, loaded: loaded)
        case .dns(let changes): step = await performDNS(changes)
        case .clearDNSCache: step = await performClearCache()
        }
        await gate.release(token)
        await log?.record(LogEvent(
            level: step.failure == nil ? .info : .warning, kind: .session,
            message: "adguard setting mutation finished \(Self.name(step.outcome)) dispatched=\(step.dispatched)"
        ))
        return report(step, startedAt: startedAt)
    }

    // MARK: Protection (gate held)

    private func performProtection(_ intent: ProtectionIntent) async -> Step {
        let before: AdGuardStatusResponse
        do {
            before = try await transport.readStatus()
        } catch {
            return (.rejected(.preconditionFailed("status unavailable")), false, Self.category(for: error))
        }
        let beforeState = Self.protectionState(from: before, now: clock())

        let wire = intent.wire
        if let stop = await dispatch(.protection(enabled: wire.enabled, durationMilliseconds: wire.durationMilliseconds)) {
            return stop
        }

        let poll = await poll { try await transport.readStatus() } matches: { matches(intent, response: $0) }
        if let matched = poll.matched {
            return (.verifiedSuccess(.protection(Self.protectionState(from: matched, now: clock()))), true, nil)
        }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        let actual = Self.protectionState(from: last, now: clock())
        if Self.sameKind(actual, beforeState) {
            let intended = Self.intendedState(for: intent, now: clock())
            return (.verifiedMismatch(expected: .protection(intended), actual: .protection(actual)), true, nil)
        }
        // Neither the old state nor the asked one: someone else changed it.
        return (.conflictingExternalEdit(actual: .protection(actual)), true, nil)
    }

    // MARK: Switches (gate held)

    private func performFeature(_ feature: AdGuardFeature, enabled: Bool) async -> Step {
        let before: JSONValue
        do {
            before = try await transport.readFeature(feature)
        } catch {
            return (.rejected(.preconditionFailed("status unavailable")), false, Self.category(for: error))
        }
        if before["enabled"]?.bool == enabled { return (.verifiedSuccess(.feature(enabled)), false, nil) }

        let write: AdGuardWrite
        if feature == .safeSearch {
            // The engine flags go back exactly as read.
            guard var settings = before.object else {
                return (.rejected(.preconditionFailed("AdGuard Home did not send its Safe Search settings.")), false, .malformedResponse)
            }
            settings["enabled"] = .bool(enabled)
            write = .safeSearchSettings(.object(settings))
        } else {
            write = .feature(feature, enabled: enabled)
        }
        if let stop = await dispatch(write) { return stop }

        let poll = await poll { try await transport.readFeature(feature) } matches: { $0["enabled"]?.bool == enabled }
        if poll.matched != nil { return (.verifiedSuccess(.feature(enabled)), true, nil) }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        return (.verifiedMismatch(expected: .feature(enabled), actual: .feature(last["enabled"]?.bool)), true, nil)
    }

    // MARK: Filter requests (gate held)

    private func performFiltering(enabled: Bool) async -> Step {
        let before: AdGuardFilteringStatus
        do {
            before = try await transport.readFiltering()
        } catch {
            return (.rejected(.preconditionFailed("status unavailable")), false, Self.category(for: error))
        }
        if before.enabled == enabled { return (.verifiedSuccess(.feature(enabled)), false, nil) }
        // The update interval goes back as read; without it nothing is sent.
        guard let interval = before.intervalHours else {
            return (.rejected(.preconditionFailed("AdGuard Home did not send its list update interval.")), false, .malformedResponse)
        }
        if let stop = await dispatch(.filteringConfig(enabled: enabled, intervalHours: interval)) { return stop }

        let poll = await poll { try await transport.readFiltering() } matches: { $0.enabled == enabled }
        if poll.matched != nil { return (.verifiedSuccess(.feature(enabled)), true, nil) }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        return (.verifiedMismatch(expected: .feature(enabled), actual: .feature(last.enabled)), true, nil)
    }

    // MARK: Domain rule (gate held)

    /// Custom rules are written whole (`set_rules`), so the list is read
    /// first under the gate, changed by one line, and sent back.
    private func performDomainRule(_ action: DomainRuleAction, domain: String) async -> Step {
        let before: [String]
        do {
            before = try await transport.readUserRules()
        } catch {
            return (.rejected(.preconditionFailed("rules unavailable")), false, Self.category(for: error))
        }
        if action.isApplied(in: before, domain: domain) { return (.verifiedSuccess(.rule(applied: true)), false, nil) }
        guard let rules = action.apply(to: before, domain: domain) else {
            return (.rejected(.invalidIntent("Not a domain name")), false, nil)
        }
        if let stop = await dispatch(.setRules(rules)) { return stop }

        let poll = await poll { try await transport.readUserRules() } matches: { action.isApplied(in: $0, domain: domain) }
        if poll.matched != nil { return (.verifiedSuccess(.rule(applied: true)), true, nil) }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        if last != before {
            // The rules changed, but not to what was sent: another edit.
            return (.conflictingExternalEdit(actual: .rule(applied: false)), true, nil)
        }
        return (.verifiedMismatch(expected: .rule(applied: true), actual: .rule(applied: false)), true, nil)
    }

    // MARK: Filters (gate held)

    /// One fresh `filtering/status` read before a list or interval write.
    private enum Before { case read(AdGuardFilteringStatus), stop(Step) }

    private func readFilteringBefore() async -> Before {
        do {
            return .read(try await transport.readFiltering())
        } catch {
            return .stop((.rejected(.preconditionFailed("status unavailable")), false, Self.category(for: error)))
        }
    }

    /// Dispatch once, then poll `filtering/status` until `matches`. A
    /// mismatch reports what AdGuard Home has (`resync`).
    private func writeFiltering(_ write: AdGuardWrite, expected: AdGuardFilteringStatus,
                                matches: (AdGuardFilteringStatus) -> Bool) async -> Step {
        if let stop = await dispatch(write) { return stop }
        let poll = await poll { try await transport.readFiltering() } matches: { matches($0) }
        if let matched = poll.matched { return (.verifiedSuccess(.filters(matched)), true, nil) }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        return (.verifiedMismatch(expected: .filters(expected), actual: .filters(last)), true, nil)
    }

    private func performListEnabled(_ kind: FilterListKind, url: String, enabled: Bool) async -> Step {
        let before: AdGuardFilteringStatus
        switch await readFilteringBefore() {
        case .read(let value): before = value
        case .stop(let stop): return stop
        }
        guard let list = before.list(kind, url: url), let listURL = list.url else {
            return (.rejected(.preconditionFailed("AdGuard Home no longer has this list. Refresh to check.")), false, nil)
        }
        if list.enabled == enabled { return (.verifiedSuccess(.filters(before)), false, nil) }
        // `set_url` replaces name and URL too, so both go back as read.
        guard let name = list.name else {
            return (.rejected(.preconditionFailed("AdGuard Home did not send the list's name.")), false, .malformedResponse)
        }
        var expected = before
        Self.setEnabled(enabled, url: listURL, kind: kind, in: &expected)
        return await writeFiltering(.setList(url: listURL, whitelist: kind.isAllowlist, name: name, enabled: enabled),
                                    expected: expected) { $0.list(kind, url: listURL)?.enabled == enabled }
    }

    private func performAddList(_ kind: FilterListKind, name: String, url: String) async -> Step {
        guard let url = FilterListURL.validated(url) else {
            return (.rejected(.invalidIntent("Enter a URL that starts with http:// or https://.")), false, nil)
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let before: AdGuardFilteringStatus
        switch await readFilteringBefore() {
        case .read(let value): before = value
        case .stop(let stop): return stop
        }
        if before.list(kind, url: url) != nil {
            return (.rejected(.preconditionFailed("AdGuard Home already has a list with this URL.")), false, nil)
        }
        var expected = before
        let added = AdGuardFilterList(name: name, url: url, enabled: true)
        if kind == .blocklist { expected.blocklists.append(added) } else { expected.allowlists.append(added) }
        return await writeFiltering(.addList(name: name, url: url, whitelist: kind.isAllowlist), expected: expected) {
            $0.list(kind, url: url) != nil
        }
    }

    private func performRemoveList(_ kind: FilterListKind, url: String) async -> Step {
        let before: AdGuardFilteringStatus
        switch await readFilteringBefore() {
        case .read(let value): before = value
        case .stop(let stop): return stop
        }
        // Already gone: nothing to send.
        guard let listURL = before.list(kind, url: url)?.url else { return (.verifiedSuccess(.filters(before)), false, nil) }
        var expected = before
        expected.blocklists.removeAll { kind == .blocklist && $0.url == listURL }
        expected.allowlists.removeAll { kind == .allowlist && $0.url == listURL }
        return await writeFiltering(.removeList(url: listURL, whitelist: kind.isAllowlist), expected: expected) {
            $0.list(kind, url: listURL) == nil
        }
    }

    private func performInterval(hours: Int) async -> Step {
        let before: AdGuardFilteringStatus
        switch await readFilteringBefore() {
        case .read(let value): before = value
        case .stop(let stop): return stop
        }
        if before.intervalHours == hours { return (.verifiedSuccess(.filters(before)), false, nil) }
        // "Filter requests" goes back as read; without it nothing is sent.
        guard let enabled = before.enabled else {
            return (.rejected(.preconditionFailed("AdGuard Home did not send whether it filters requests.")), false, .malformedResponse)
        }
        var expected = before
        expected.intervalHours = hours
        return await writeFiltering(.filteringConfig(enabled: enabled, intervalHours: hours), expected: expected) {
            $0.intervalHours == hours
        }
    }

    /// Recovery class `none`: the count comes from the reply; the read
    /// after it only refreshes the lists.
    private func performUpdateLists(_ kind: FilterListKind) async -> Step {
        let updated: Int?
        do {
            updated = try await transport.refreshLists(kind)
        } catch AdGuardClientError.credentialUnavailable {
            return (.rejected(.preconditionFailed("credential unavailable")), false, .authentication)
        } catch AdGuardClientError.unauthorized {
            return (.rejected(.preconditionFailed("AdGuard Home refused the login")), true, .authentication)
        } catch {
            return (.unknownAfterDispatch, true, Self.category(for: error))
        }
        let after = try? await transport.readFiltering()
        return (.verifiedSuccess(.listsUpdated(updated, after)), true, nil)
    }

    private func performSaveRules(_ rules: [String], loaded: [String]) async -> Step {
        let before: [String]
        do {
            before = try await transport.readUserRules()
        } catch {
            return (.rejected(.preconditionFailed("rules unavailable")), false, Self.category(for: error))
        }
        if before == rules { return (.verifiedSuccess(.rules(rules)), false, nil) }
        // Someone changed the rules after the editor loaded them: stop
        // rather than overwrite their change.
        if before != loaded { return (.conflictingExternalEdit(actual: .rules(before)), false, nil) }
        if let stop = await dispatch(.setRules(rules)) { return stop }

        let poll = await poll { try await transport.readUserRules() } matches: { $0 == rules }
        if poll.matched != nil { return (.verifiedSuccess(.rules(rules)), true, nil) }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        if last != before { return (.conflictingExternalEdit(actual: .rules(last)), true, nil) }
        return (.verifiedMismatch(expected: .rules(rules), actual: .rules(last)), true, nil)
    }

    // MARK: DNS (gate held)

    /// Sends only the changed fields, so a field changed elsewhere since the
    /// tab read it is not written back.
    private func performDNS(_ changes: [String: JSONValue]) async -> Step {
        let before: AdGuardDNSSettings
        do {
            before = try await transport.readDNS()
        } catch {
            return (.rejected(.preconditionFailed("DNS settings unavailable")), false, Self.category(for: error))
        }
        if before.contains(changes) { return (.verifiedSuccess(.dns(before)), false, nil) }
        if let stop = await dispatch(.dnsConfig(changes)) { return stop }

        let poll = await poll { try await transport.readDNS() } matches: { $0.contains(changes) }
        if let matched = poll.matched { return (.verifiedSuccess(.dns(matched)), true, nil) }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        return (.verifiedMismatch(expected: .dns(before.applying(changes)), actual: .dns(last)), true, nil)
    }

    /// Recovery class `none`: nothing can be read back.
    private func performClearCache() async -> Step {
        do {
            try await transport.write(.clearDNSCache)
            return (.verifiedSuccess(.cacheCleared), true, nil)
        } catch AdGuardClientError.credentialUnavailable {
            return (.rejected(.preconditionFailed("credential unavailable")), false, .authentication)
        } catch AdGuardClientError.unauthorized {
            return (.rejected(.preconditionFailed("AdGuard Home refused the login")), true, .authentication)
        } catch {
            return (.unknownAfterDispatch, true, Self.category(for: error))
        }
    }

    public func testUpstreams(_ request: UpstreamTestRequest, availability: AdGuardAvailability) async -> Result<UpstreamTestResult, RefreshFailureCategory> {
        guard availability == .running else { return .failure(.unavailable) }
        do {
            return .success(UpstreamTestResult.parse(try await transport.testUpstreams(request)))
        } catch {
            return .failure(Self.category(for: error))
        }
    }

    private static func setEnabled(_ enabled: Bool, url: String, kind: FilterListKind, in status: inout AdGuardFilteringStatus) {
        func update(_ lists: inout [AdGuardFilterList]) {
            for index in lists.indices where lists[index].url == url { lists[index].enabled = enabled }
        }
        if kind == .blocklist { update(&status.blocklists) } else { update(&status.allowlists) }
    }

    // MARK: Dispatch and verify

    /// Sends the write once. Returns a final step when nothing was sent or
    /// AdGuard Home refused the sign-in; `nil` means verify.
    private func dispatch(_ write: AdGuardWrite) async -> Step? {
        do {
            try await transport.write(write)
            return nil
        } catch AdGuardClientError.credentialUnavailable {
            // No request was ever sent; nothing ambiguous happened.
            return (.rejected(.preconditionFailed("credential unavailable")), false, .authentication)
        } catch AdGuardClientError.unauthorized {
            // A request reached the server and was rejected as unauthorized
            // (including the single re-dispatch after a 401/403). AdGuard
            // Home never applies a write it rejects with 401/403, so there
            // is nothing to verify; it still counts as dispatched.
            return (.rejected(.preconditionFailed("AdGuard Home refused the login")), true, .authentication)
        } catch {
            // Timeout, lost response, non-2xx after the retry: the write may
            // have applied. Verification decides.
            return nil
        }
    }

    private func poll<Value: Sendable>(
        read: () async throws -> Value, matches: (Value) -> Bool
    ) async -> (matched: Value?, last: Value?, failure: RefreshFailureCategory?) {
        let deadline = clock().addingTimeInterval(Self.seconds(policy.deadline))
        var last: Value?
        var lastFailure: RefreshFailureCategory?
        while clock() < deadline {
            do {
                let value = try await read()
                last = value
                lastFailure = nil
                if matches(value) { return (value, value, nil) }
            } catch {
                lastFailure = Self.category(for: error)
            }
            // `try?`: a cancelled sleep must not stop verification of an
            // already-dispatched write. We simply loop again immediately.
            try? await sleep(policy.pollInterval)
        }
        return (nil, last, lastFailure)
    }

    // MARK: Mapping

    static func protectionState(from response: AdGuardStatusResponse, now: Date) -> ProtectionState {
        switch response.protectionEnabled {
        case true?:
            return .enabled
        case false?:
            if let duration = response.protectionDisabledDurationMilliseconds, duration > 0 {
                return .paused(until: now.addingTimeInterval(TimeInterval(duration) / 1000))
            }
            return .disabled
        case nil:
            return .unknown
        }
    }

    private static func sameKind(_ lhs: ProtectionState, _ rhs: ProtectionState) -> Bool {
        switch (lhs, rhs) {
        case (.enabled, .enabled), (.disabled, .disabled), (.paused, .paused), (.unknown, .unknown): true
        default: false
        }
    }

    private static func intendedState(for intent: ProtectionIntent, now: Date) -> ProtectionState {
        switch intent {
        case .enable: .enabled
        case .disable: .disabled
        case .pause(let duration): .paused(until: now.addingTimeInterval(seconds(duration)))
        }
    }

    private func matches(_ intent: ProtectionIntent, response: AdGuardStatusResponse) -> Bool {
        switch intent {
        case .enable:
            return response.protectionEnabled == true
        case .disable:
            // AdGuard Home may omit `protection_disabled_duration` entirely
            // when protection is disabled indefinitely; treat a missing
            // field the same as 0, not as "still has a duration".
            return response.protectionEnabled == false && (response.protectionDisabledDurationMilliseconds ?? 0) == 0
        case .pause(let duration):
            guard response.protectionEnabled == false,
                  let observedMs = response.protectionDisabledDurationMilliseconds, observedMs > 0 else {
                return false
            }
            let requestedMs = ProtectionIntent.milliseconds(from: duration)
            let toleranceMs = ProtectionIntent.milliseconds(from: policy.pauseTolerance)
            return observedMs <= requestedMs && observedMs >= requestedMs - toleranceMs
        }
    }

    static func category(for error: Error) -> RefreshFailureCategory {
        switch error {
        case let error as AdGuardClientError: LiveRouterBackend.category(for: error)
        case let error as TransportError: LiveRouterBackend.category(for: error)
        default: .unavailable
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func name(_ outcome: MutationOutcome<AdGuardSettingState>) -> String {
        switch outcome {
        case .rejected: "rejected"
        case .verifiedSuccess: "verifiedSuccess"
        case .verifiedMismatch: "verifiedMismatch"
        case .verifiedRecovery: "verifiedRecovery"
        case .recoveryFailed: "recoveryFailed"
        case .conflictingExternalEdit: "conflictingExternalEdit"
        case .unknownAfterDispatch: "unknownAfterDispatch"
        }
    }

    private func report(_ step: Step, startedAt: Date) -> MutationReport<AdGuardSettingState> {
        MutationReport(outcome: step.outcome, dispatched: step.dispatched, startedAt: startedAt, finishedAt: clock(), failure: step.failure)
    }
}

/// The live calls: AdGuard Home's own API.
public struct LiveAdGuardSettingTransport: AdGuardSettingTransport {
    let adGuard: AdGuardClient

    public init(adGuard: AdGuardClient) { self.adGuard = adGuard }

    public func readStatus() async throws -> AdGuardStatusResponse { try await adGuard.status() }
    public func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue {
        try await adGuard.read(.status(of: feature))
    }
    public func readFiltering() async throws -> AdGuardFilteringStatus {
        AdGuardFilteringStatus.parse(try await adGuard.read(.filteringStatus))
    }
    public func readUserRules() async throws -> [String] {
        let json = try await adGuard.read(.filteringStatus)
        guard case .array(let rules)? = json["user_rules"] else {
            // `null` is an empty list; anything else is not the rules.
            if case .null? = json["user_rules"] { return [] }
            throw AdGuardClientError.malformedResponse
        }
        return rules.compactMap(\.string)
    }
    public func write(_ write: AdGuardWrite) async throws { try await adGuard.write(write) }
    public func refreshLists(_ kind: FilterListKind) async throws -> Int? {
        try await adGuard.write(.refreshLists(whitelist: kind.isAllowlist))?["updated"]?.int
    }
    public func readDNS() async throws -> AdGuardDNSSettings {
        guard let settings = AdGuardDNSSettings.parse(try await adGuard.read(.dnsInfo)) else { throw AdGuardClientError.malformedResponse }
        return settings
    }
    public func testUpstreams(_ request: UpstreamTestRequest) async throws -> JSONValue? {
        try await adGuard.write(.testUpstreams(request))
    }
}
