import Foundation

/// `adguardhome get_config` `[verified live]`: on 4.9.1 the whole object is
/// `{"enabled", "dns_enabled"}`. A missing or differently typed field is `nil`.
public struct AdGuardRouterConfig: Sendable, Equatable, Codable {
    /// AdGuard Home is switched on in the router's settings.
    public var enabled: Bool?
    /// `dns_enabled`: the router sends client DNS to AdGuard Home (the
    /// router UI's "Handle client requests", meaning `[assumed]`).
    public var handlesDNS: Bool?

    public init(enabled: Bool? = nil, handlesDNS: Bool? = nil) {
        self.enabled = enabled
        self.handlesDNS = handlesDNS
    }

    public static func parse(_ json: JSONValue) -> AdGuardRouterConfig {
        AdGuardRouterConfig(enabled: json["enabled"]?.bool, handlesDNS: json["dns_enabled"]?.bool)
    }
}

/// What one refresh learned about the AdGuard Home service: the router's
/// `get_config`, then `control/status` when the router says it is on.
public struct AdGuardServiceReading: Sendable, Equatable {
    public var config: Result<AdGuardRouterConfig, RefreshFailureCategory>
    /// `nil` when AdGuard Home was not asked: the config read failed or
    /// says it is off. `notConfigured` when the profile has no AdGuard Home.
    public var answer: Answer?
    public var observedAt: Date

    public enum Answer: Sendable, Equatable {
        case answered(AdGuardStatusResponse)
        case failed(RefreshFailureCategory)
        case notConfigured
    }

    public init(config: Result<AdGuardRouterConfig, RefreshFailureCategory>, answer: Answer? = nil, observedAt: Date) {
        self.config = config
        self.answer = answer
        self.observedAt = observedAt
    }

    /// The status AdGuard Home gave, when it answered.
    public var status: AdGuardStatusResponse? {
        if case .answered(let status) = answer { return status }
        return nil
    }
}

/// Why the AdGuard Home screen cannot show live data.
public enum AdGuardProblem: Sendable, Equatable {
    /// The router did not give its AdGuard Home setting.
    case routerUnreadable(RefreshFailureCategory)
    /// The router says AdGuard Home is on, but AdGuard Home did not answer.
    case notAnswering(RefreshFailureCategory)
    /// The router says AdGuard Home is on, but this profile has no AdGuard
    /// Home connection.
    case notConfigured
}

/// The AdGuard Home screen's state. Off comes only from
/// `get_config` `enabled` false; a failed call is never read as off.
public enum AdGuardAvailability: Sendable, Equatable {
    /// Not read yet in this session.
    case unknown
    /// Off on the router and no saved copy: the empty state.
    case off
    /// On, and AdGuard Home answers: every tab, writes allowed.
    case running
    /// Off on the router, with a saved copy: every tab, read-only.
    case cached
    /// On or not readable, and no answer: the saved copy, read-only, with a
    /// strip that names the problem.
    case unreachable(AdGuardProblem)

    public static func decide(_ reading: AdGuardServiceReading?, hasArchive: Bool) -> AdGuardAvailability {
        guard let reading else { return .unknown }
        switch reading.config {
        case .failure(let category):
            return .unreachable(.routerUnreadable(category))
        case .success(let config):
            switch config.enabled {
            case false?:
                return hasArchive ? .cached : .off
            case nil:
                return .unreachable(.routerUnreadable(.malformedResponse))
            case true?:
                switch reading.answer {
                case .answered?: return .running
                case .failed(let category)?: return .unreachable(.notAnswering(category))
                case .notConfigured?: return .unreachable(.notConfigured)
                case nil: return .unreachable(.notAnswering(.unavailable))
                }
            }
        }
    }

    /// Every control that writes is disabled.
    public var isReadOnly: Bool { self != .running }
}
