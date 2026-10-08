import Foundation
import Observation

/// Owns the current onboarding run and opens its window. First run starts
/// one after bootstrap; `start()` starts one on demand (15B's Start Setup
/// Again, after it removed the old router, and the Debug menu).
@MainActor @Observable
final class OnboardingController {
    private(set) var run: OnboardingModel?
    @ObservationIgnored weak var environment: AppEnvironment?
    /// Set by the scenes: open the onboarding window, open the main window,
    /// close the onboarding window.
    @ObservationIgnored var showWindow: (() -> Void)?
    @ObservationIgnored var showMainWindow: (() -> Void)?
    @ObservationIgnored var closeWindow: (() -> Void)?
    #if DEBUG
    /// `ROUTEWELL_ONBOARDING=<scenario>` with the mock backend.
    @ObservationIgnored var launchMockScenario: MockOnboardingScenario?
    #endif

    /// A new live run, always from an empty start, in its own window.
    func start() {
        guard let environment else { return }
        begin(OnboardingModel(services: LiveOnboardingServices(environment: environment)))
        showWindow?()
    }

    #if DEBUG
    func startMock(_ scenario: MockOnboardingScenario) {
        begin(OnboardingModel(services: MockOnboardingServices(scenario: scenario)))
        showWindow?()
    }
    #endif

    /// The onboarding window appeared with nothing to show: after bootstrap,
    /// start the run first launch needs, or report that none is needed.
    func runForLaunch() -> OnboardingModel? {
        if let run { return run }
        guard let environment else { return nil }
        #if DEBUG
        if let scenario = launchMockScenario {
            launchMockScenario = nil
            begin(OnboardingModel(services: MockOnboardingServices(scenario: scenario)))
            return run
        }
        #endif
        guard environment.model.needsSetup else { return nil }
        begin(OnboardingModel(services: LiveOnboardingServices(environment: environment)))
        return run
    }

    /// The window closed. Before Finish, whatever the run saved is removed.
    func windowClosed() {
        guard let current = run else { return }
        run = nil
        current.abandon()
    }

    private func begin(_ model: OnboardingModel) {
        run?.abandon()
        model.onFinish = { [weak self, weak model] in
            guard let self, let model, self.run === model else { return }
            self.run = nil
            self.showMainWindow?()
            self.closeWindow?()
        }
        run = model
    }
}
