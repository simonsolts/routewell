import Testing
@testable import RoutewellKit

@Test func refreshPolicyCoversVisibilityAndSleep() {
    var policy = RefreshPolicy()
    #expect(policy.cadence(windowVisible: true, menuBarVisible: false, sleeping: false) == .seconds(30))
    #expect(policy.cadence(windowVisible: false, menuBarVisible: true, sleeping: false) == .seconds(60))
    #expect(policy.cadence(windowVisible: false, menuBarVisible: false, sleeping: false) == nil)
    policy.pauseWhenHidden = false
    #expect(policy.cadence(windowVisible: false, menuBarVisible: false, sleeping: false) == .seconds(30))
    #expect(policy.cadence(windowVisible: true, menuBarVisible: true, sleeping: true) == nil)
    policy.interval = .zero
    #expect(policy.cadence(windowVisible: true, menuBarVisible: true, sleeping: false) == .seconds(1))
}
