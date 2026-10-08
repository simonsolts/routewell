import Foundation
import Observation
import RoutewellKit

/// The AdGuard Home screen's state (chunk 16): the last service reading,
/// the saved copy for the selected router, and the service writes. The
/// reading and the copy change together, so a cached router never shows the
/// empty state while its copy loads.
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

    /// Turn On, Stop, Handle DNS, Restart. One at a time; the executor also
    /// checks the state and holds the router's gate.
    func run(_ intent: AdGuardServiceIntent) {
        guard inFlight == nil, let lease = model.session.lease else { return }
        let availability = availability
        let store = store
        let profile = profileID()
        inFlight = intent
        lastIntent = intent
        lastReport = nil
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
                // The design opens Overview once AdGuard Home runs.
                self.model.subpages[.adGuard] = AdGuardTab.overview.rawValue
            }
            self.refresh.refreshNow()
        }
    }

    /// Clears the last result, for example when the screen changes.
    func dismissReport() { lastReport = nil }
}
