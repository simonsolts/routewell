import Foundation
import Observation
import RoutewellKit

/// What AdGuard Home › Query Log opens searching for: a domain
/// from Top blocked or Top queried, or a client IP from Top devices or
/// Clients' Show DNS Log. AdGuard Home has one search for both.
struct AdGuardQueryLogFilter: Equatable, Sendable {
    var search: String
}

/// The AdGuard Home screen's state: the last service reading, the saved
/// copy for the selected router, and the writes, plus the
/// Overview's reads, range, and setting writes. The reading and
/// the copy change together, so a cached router never shows the empty
/// state while its copy loads.
@MainActor @Observable
final class AdGuardController {
    private let model: AppModel
    private let refresh: RefreshController
    private let store: AdGuardArchiveStore
    /// The selected router profile; the copy is kept per profile.
    @ObservationIgnored var profileID: () -> UUID? = { nil }

    private(set) var reading: AdGuardServiceReading?
    private(set) var archive: AdGuardArchive?
    private var readingToken: SessionToken?
    private(set) var inFlight: AdGuardServiceIntent?
    private(set) var lastReport: MutationReport<AdGuardServiceState>?
    private(set) var lastIntent: AdGuardServiceIntent?

    // Overview
    private(set) var overview: AdGuardOverviewReading?
    private var overviewToken: SessionToken?
    /// The Activity range. Changing it reads that range at once.
    private(set) var range: AdGuardStatsRange = .day
    /// AdGuard Home did not honour `recent`: only one range is offered.
    private(set) var rangesUnsupported = false
    private var overviewGeneration = 0
    @ObservationIgnored private var rangeTask: Task<Void, Never>?
    private(set) var settingInFlight: AdGuardSettingIntent?
    private(set) var lastSettingReport: MutationReport<AdGuardSettingState>?
    private(set) var lastSettingIntent: AdGuardSettingIntent?
    /// Verified setting writes and when they finished. A read that started
    /// before that time shows the verified value, not its older one.
    private var verifiedProtection: (state: ProtectionState, at: Date)?
    private var verifiedFeatures: [AdGuardFeature: (value: Bool, at: Date)] = [:]
    private var verifiedFiltering: (value: Bool, at: Date)?
    private var verifiedFilters: (status: AdGuardFilteringStatus, at: Date)?
    private var verifiedDNS: (settings: AdGuardDNSSettings, at: Date)?
    private var verifiedRetention: [AdGuardDataKind: (milliseconds: Int, at: Date)] = [:]
    /// The update check, read once per session.
    private var version: (token: SessionToken, check: AdGuardVersionCheck)?
    private var versionReading: SessionToken?
    @ObservationIgnored private var pauseEndTask: Task<Void, Never>?

    init(model: AppModel, refresh: RefreshController, store: AdGuardArchiveStore) {
        self.model = model
        self.refresh = refresh
        self.store = store
    }

    /// Readings from an earlier session never count.
    var availability: AdGuardAvailability {
        guard readingToken != nil, readingToken == model.session.expectedToken else { return .unknown }
        return AdGuardAvailability.decide(reading, hasArchive: archive != nil)
    }

    /// The Handle DNS setting to show: live while running, else the saved one.
    var handlesDNS: Bool? {
        if availability == .running, case .success(let config)? = reading?.config { return config.handlesDNS }
        return archive?.config?.value.handlesDNS
    }

    /// AdGuard Home's status: live while running, else the saved one.
    var status: AdGuardStatusResponse? {
        availability == .running ? reading?.status : archive?.status?.value
    }

    /// The tab bar shows whenever there is something to show in the tabs.
    var showsTabs: Bool {
        switch availability {
        case .running, .cached: true
        case .unreachable: archive != nil
        case .off, .unknown: false
        }
    }

    /// A service or setting write is running.
    var isWriting: Bool { inFlight != nil || settingInFlight != nil }

    // MARK: Overview values (live while running, else the saved copy)

    /// The Overview read for this session, while running.
    private var liveOverview: AdGuardOverviewReading? {
        guard availability == .running, overviewToken == model.session.expectedToken else { return nil }
        return overview
    }

    /// Protection on, off, or paused. A paused state ends at the time the
    /// reading implies.
    var protection: ProtectionState? {
        if availability == .running {
            guard let reading else { return nil }
            if let verified = verifiedProtection, reading.observedAt < verified.at { return verified.state }
            guard let status = reading.status else { return nil }
            return AdGuardClient.adGuardStatus(status: status, stats: nil, now: reading.observedAt).protection
        }
        guard let saved = archive?.status else { return nil }
        return AdGuardClient.adGuardStatus(status: saved.value, stats: nil, now: saved.savedAt).protection
    }

    /// Stats for the selected range; `savedAt` is set for the saved copy.
    var stats: (value: AdGuardStats, savedAt: Date?)? {
        if availability == .running {
            guard let live = liveOverview, live.range == range, case .success(let stats) = live.stats else { return nil }
            return (stats, nil)
        }
        return archive?.stats(for: range).map { ($0.value, $0.savedAt) }
    }

    /// The live read of the selected range failed.
    var statsFailure: RefreshFailureCategory? {
        guard let live = liveOverview, live.range == range, case .failure(let category) = live.stats else { return nil }
        return category
    }

    var statsConfig: AdGuardStatsConfig? {
        guard availability == .running else { return archive?.statsConfig?.value }
        guard let live = liveOverview, var config = try? live.statsConfig.get() else { return nil }
        if let verified = verifiedRetention[.stats], live.observedAt < verified.at { config.intervalMilliseconds = verified.milliseconds }
        return config
    }

    var queryLogConfig: AdGuardQueryLogConfig? {
        guard availability == .running else { return archive?.instance?.value.queryLog }
        guard let live = liveOverview, var config = try? live.queryLog.get() else { return nil }
        if let verified = verifiedRetention[.queryLog], live.observedAt < verified.at { config.intervalMilliseconds = verified.milliseconds }
        return config
    }

    /// The update check: this session's while running, else the saved one.
    var versionCheck: AdGuardVersionCheck? {
        guard availability == .running else { return archive?.instance?.value.version }
        guard let version, version.token == model.session.expectedToken else { return nil }
        return version.check
    }

    /// Reads `version.json` once per session while AdGuard Home runs. Each
    /// read can make AdGuard Home ask the internet, so refreshes skip it.
    func loadVersionCheck() async {
        guard availability == .running, let lease = model.session.lease, let profile = profileID(),
              version?.token != lease.token, versionReading != lease.token else { return }
        versionReading = lease.token
        defer { if versionReading == lease.token { versionReading = nil } }
        guard case .success(let check)? = try? await model.session.routerSession.adGuardVersionCheck(using: lease),
              lease.token == model.session.expectedToken else { return }
        version = (lease.token, check)
        await store.save(version: check, at: Date(), for: profile)
        if profile == profileID() { archive = await store.archive(for: profile) }
    }

    var protectionOptions: ProtectionOptions? {
        guard availability == .running else { return archive?.protection?.value }
        guard let live = liveOverview, var options = try? live.protection.get() else { return nil }
        for (feature, verified) in verifiedFeatures where live.observedAt < verified.at {
            options[feature] = verified.value
        }
        return options
    }

    var filtering: AdGuardFilteringStatus? {
        guard availability == .running else { return archive?.filtering?.value }
        guard let live = liveOverview, var status = try? live.filtering.get() else { return nil }
        if let verified = verifiedFilters, live.observedAt < verified.at { status = verified.status }
        if let verified = verifiedFiltering, live.observedAt < verified.at { status.enabled = verified.value }
        return status
    }

    /// The live DNS read failed.
    var dnsFailure: RefreshFailureCategory? {
        guard let live = liveOverview, case .failure(let category) = live.dns else { return nil }
        return category
    }

    var dnsSettings: AdGuardDNSSettings? {
        guard availability == .running else { return archive?.dns?.value }
        guard let live = liveOverview, let settings = try? live.dns.get() else { return nil }
        if let verified = verifiedDNS, live.observedAt < verified.at { return verified.settings }
        return settings
    }

    /// The ranges the pop-up offers. Running: up to the stats retention.
    /// Read-only: the ranges the saved copy holds.
    var availableRanges: [AdGuardStatsRange] {
        if availability == .running {
            if rangesUnsupported { return [.day] }
            return AdGuardStatsRange.allCases.filter { $0.isAvailable(retentionMilliseconds: statsConfig?.intervalMilliseconds) }
        }
        return AdGuardStatsRange.allCases.filter { archive?.stats(for: $0) != nil }
    }

    // MARK: Readings

    /// Each overview refresh: save the sections a running read gives, then
    /// show the reading together with the copy it decides against.
    func observe(_ reading: AdGuardServiceReading, token: SessionToken) async {
        guard token == model.session.expectedToken, let profile = profileID() else { return }
        await store.save(reading, for: profile)
        let saved = await store.archive(for: profile)
        guard token == model.session.expectedToken, profile == profileID() else { return }
        archive = saved
        self.reading = reading
        readingToken = token
        schedulePauseEnd()
    }

    /// The Overview tab's reads, from the refresh loop and a range change.
    /// Only while AdGuard Home runs; the read-only tabs show the saved copy.
    func refreshOverview(using lease: SessionLease) async throws {
        guard availability == .running, let profile = profileID() else { return }
        let range = range
        let generation = overviewGeneration
        guard let reading = try await model.session.routerSession.adGuardOverview(using: lease, range: range) else { return }
        await store.save(reading, for: profile)
        let saved = await store.archive(for: profile)
        guard lease.token == model.session.expectedToken, profile == profileID() else { return }
        archive = saved
        // A newer range was picked while this one was read.
        guard generation == overviewGeneration else { return }
        // A new session starts by offering every range again.
        if overviewToken != lease.token { rangesUnsupported = false }
        overview = reading
        overviewToken = lease.token
        if !reading.rangeHonoured {
            // This AdGuard Home ignores `recent`: one range, labelled with
            // the period the stats really cover.
            rangesUnsupported = true
            setRange(.day)
        } else if !range.isAvailable(retentionMilliseconds: try? reading.statsConfig.get().intervalMilliseconds),
                  case .success = reading.statsConfig {
            // The retention got shorter than the range.
            setRange(.day)
        }
    }

    /// Reads the overview at once while the AdGuard Home screen is visible;
    /// `false` when it is not or AdGuard Home is not running.
    func refreshOverviewNow() async -> Bool {
        guard model.selection == .adGuard, availability == .running, let lease = model.session.lease else { return false }
        try? await refreshOverview(using: lease)
        return true
    }

    func setRange(_ value: AdGuardStatsRange) {
        guard value != range else { return }
        range = value
        overviewGeneration += 1
        rangeTask?.cancel()
        guard availability == .running, let lease = model.session.lease else { return }
        rangeTask = Task { [weak self] in try? await self?.refreshOverview(using: lease) }
    }

    /// Asks for a refresh just after a timed pause ends, so the banner
    /// shows protection back on without waiting for the next tick.
    private func schedulePauseEnd() {
        pauseEndTask?.cancel()
        guard case .paused(let until)? = protection else { return }
        let wait = max(0, until.timeIntervalSinceNow) + 1
        pauseEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.refresh.refreshNow()
        }
    }

    /// Start Setup Again: the copy goes with the router.
    func removeArchive(profile: UUID) async {
        await store.remove(profile: profile)
        if profile == profileID() || profileID() == nil {
            archive = nil
        }
    }

    #if DEBUG
    /// Mock scenarios seed or clear the saved copy for the selected profile.
    func replaceArchive(_ value: AdGuardArchive?) async {
        guard let profile = profileID() else { return }
        await store.replace(value, for: profile)
        archive = await store.archive(for: profile)
    }
    #endif

    // MARK: Writes

    /// Turn On, Stop, Handle DNS, Restart. One write at a time; the executor
    /// also checks the state and holds the router's gate.
    func run(_ intent: AdGuardServiceIntent) {
        guard !isWriting, let lease = model.session.lease else { return }
        let availability = availability
        let store = store
        let profile = profileID()
        let range = range
        inFlight = intent
        lastIntent = intent
        lastReport = nil
        lastSettingReport = nil
        Task { [weak self] in
            guard let self else { return }
            let report: MutationReport<AdGuardServiceState>
            do {
                report = try await self.model.session.routerSession.runAdGuardService(
                    using: lease, intent: intent, availability: availability
                ) { reading in
                    // Stop: one final sync, so the copy is as new as possible.
                    guard let profile else { return }
                    await store.save(reading, for: profile, force: true)
                    // At most 5 s: the gate is held, and nothing is sent until
                    // this sync ends.
                    if let service = lease.backend.adGuardOverview,
                       let overview = await Self.within(.seconds(5), { try? await service.overview(range: range) }) {
                        await store.save(overview, for: profile, force: true)
                    }
                }
            } catch {
                // The session changed during the write: its result belongs
                // to no one. The new session reads the router afresh.
                self.inFlight = nil
                return
            }
            guard lease.token == self.model.session.expectedToken else { self.inFlight = nil; return }
            self.lastReport = report
            self.inFlight = nil
            if case .turnOn = intent, case .verifiedSuccess = report.outcome {
                // Overview opens once AdGuard Home runs.
                self.model.subpages[.adGuard] = AdGuardTab.overview.rawValue
            }
            self.refresh.refreshNow()
        }
    }

    /// Pause, Resume, Turn Off Protection, and the three switches. Rejected
    /// by the executor unless AdGuard Home runs.
    func runSetting(_ intent: AdGuardSettingIntent) {
        startSetting(intent)
    }

    /// Starts one setting write; the task gives its report (`nil` when the
    /// session changed). `nil` when another write runs.
    @discardableResult
    func startSetting(_ intent: AdGuardSettingIntent) -> Task<MutationReport<AdGuardSettingState>?, Never>? {
        guard !isWriting, let lease = model.session.lease else { return nil }
        let availability = availability
        settingInFlight = intent
        lastSettingIntent = intent
        lastSettingReport = nil
        lastReport = nil
        return Task { [weak self] in
            guard let self else { return nil }
            let report: MutationReport<AdGuardSettingState>
            do {
                report = try await self.model.session.routerSession.runAdGuardSetting(
                    using: lease, intent: intent, availability: availability
                )
            } catch {
                // The session changed during the write: never re-sent; the
                // new session reads AdGuard Home afresh.
                self.settingInFlight = nil
                return nil
            }
            guard lease.token == self.model.session.expectedToken else { self.settingInFlight = nil; return nil }
            self.lastSettingReport = report
            if case .verifiedSuccess(let state) = report.outcome {
                // Show the verified value until the refresh lands.
                switch (intent, state) {
                case (.protection, .protection(let protection)):
                    self.verifiedProtection = (protection, report.finishedAt)
                    self.schedulePauseEnd()
                case (.feature(let feature, _), .feature(let value?)):
                    self.verifiedFeatures[feature] = (value, report.finishedAt)
                case (.filtering, .feature(let value?)):
                    self.verifiedFiltering = (value, report.finishedAt)
                case (_, .filters(let status)), (_, .listsUpdated(_, let status?)):
                    self.verifiedFilters = (status, report.finishedAt)
                case (_, .dns(let settings)):
                    self.verifiedDNS = (settings, report.finishedAt)
                case (_, .retention(let kind, let milliseconds?)):
                    self.verifiedRetention[kind] = (milliseconds, report.finishedAt)
                case (_, .rules(let rules)):
                    if var status = self.filtering {
                        status.userRules = rules
                        self.verifiedFilters = (status, report.finishedAt)
                    }
                default: break
                }
            }
            self.settingInFlight = nil
            if case .rejected = report.outcome {
                // A rejected write changed nothing.
            } else {
                self.refresh.refreshNow()
            }
            return report
        }
    }

    /// Test Upstreams. `nil` when the session changed or there is none.
    func testUpstreams(_ request: UpstreamTestRequest) async -> Result<UpstreamTestResult, RefreshFailureCategory>? {
        guard let lease = model.session.lease else { return nil }
        let availability = availability
        return try? await model.session.routerSession.testAdGuardUpstreams(using: lease, request: request, availability: availability)
    }

    /// The value, or `nil` when it takes longer than `limit` (the read is
    /// cancelled).
    nonisolated private static func within<Value: Sendable>(
        _ limit: Duration, _ body: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await body() }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
