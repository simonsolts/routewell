import Foundation
import RoutewellKit

/// Text and tones for the AdGuard Home screen (design/adguard-home.md), kept
/// out of the views so tests can check them.
enum AdGuardPresentation {
    /// "Oct 7 at 15:02", as in the design's strip.
    static func savedDate(_ date: Date) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(day) at \(time)"
    }

    enum StripAction: Equatable { case turnOn, openRouterSettings }

    struct Strip: Equatable {
        let title: String
        let message: String
        let action: StripAction
    }

    /// The read-only strip under the toolbar. "Search and export still work"
    /// comes back with the Query Log in chunk 18, which builds them.
    static func strip(_ availability: AdGuardAvailability, archive: AdGuardArchive?) -> Strip? {
        guard let savedAt = archive?.savedAt else { return nil }
        let message = "Showing a read-only copy saved \(savedDate(savedAt))."
        switch availability {
        case .cached:
            return Strip(title: "AdGuard Home is off", message: message, action: .turnOn)
        case .unreachable(let problem):
            return Strip(title: problemTitle(problem), message: message, action: .openRouterSettings)
        case .running, .off, .unknown:
            return nil
        }
    }

    /// Names the problem; never says "off" (architecture 03).
    static func problemTitle(_ problem: AdGuardProblem) -> String {
        switch problem {
        case .routerUnreadable: "The router did not say whether AdGuard Home is on"
        case .notAnswering(.authentication): "AdGuard Home refused the sign-in"
        case .notAnswering: "AdGuard Home is not answering"
        case .notConfigured: "AdGuard Home is not set up in Routewell"
        }
    }

    /// The sidebar dot: green running, orange paused, grey for the saved
    /// copy, red when AdGuard Home is on but does not answer; none when off.
    static func sidebarTone(_ availability: AdGuardAvailability, protection: ProtectionState?) -> StatusTone? {
        switch availability {
        case .running:
            if case .paused? = protection { return .degraded }
            return .healthy
        case .cached: return .unknown
        case .unreachable: return .error
        case .off, .unknown: return nil
        }
    }

    /// The Instance header's second line.
    static func instanceLine(_ availability: AdGuardAvailability, status: AdGuardStatusResponse?, sshConfigured: Bool, now: Date) -> String {
        var parts: [String] = []
        switch availability {
        case .running:
            if let start = status?.startTime {
                parts.append("Running for \(uptime(from: start, to: now))")
            } else {
                parts.append("Running")
            }
        case .cached: parts.append("Stopped")
        case .unreachable: parts.append("Not answering")
        case .off, .unknown: parts.append("Unknown")
        }
        if let version = status?.version { parts.append("Version \(version)") }
        // Memory is read over SSH from chunk 19B.
        if availability == .running, !sshConfigured { parts.append("Memory needs SSH") }
        return parts.joined(separator: " · ")
    }

    /// "13 days", "5 hours", "12 minutes": the largest whole unit.
    static func uptime(from start: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        guard seconds >= 60 else { return "less than a minute" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: seconds) ?? "Unknown"
    }

    /// The line under the Instance header or the empty state after a write.
    /// `nil` when the write did what was asked.
    static func outcomeText(_ intent: AdGuardServiceIntent, _ outcome: MutationOutcome<AdGuardServiceState>) -> String? {
        switch outcome {
        case .verifiedSuccess, .verifiedRecovery:
            return nil
        case .verifiedMismatch(_, let actual):
            switch intent {
            case .turnOn:
                return actual.enabled == true
                    ? "AdGuard Home is on, but it did not answer in time. Refresh to check."
                    : "The router did not turn AdGuard Home on."
            case .turnOff:
                return "The router did not turn AdGuard Home off."
            case .setHandlesDNS:
                return "The router did not change Handle DNS requests."
            case .restart:
                switch actual.enabled {
                case false?: return "AdGuard Home is off after the restart. Turn it on to start it again."
                case true? where actual.answering == false: return "AdGuard Home did not answer after the restart. Refresh to check."
                default: return "The router did not restart AdGuard Home."
                }
            }
        case .unknownAfterDispatch:
            return "The router did not answer in time. The change may have applied. Refresh to check."
        case .recoveryFailed, .conflictingExternalEdit:
            return "AdGuard Home changed from somewhere else. Refresh to check."
        case .rejected(let rejection):
            switch rejection {
            case .gateBusy: return "Another change is still running."
            case .staleSession: return "The router changed during the operation. Refresh to check."
            case .capabilityUnavailable: return "This router cannot change AdGuard Home from Routewell."
            case .preconditionFailed(let reason), .invalidIntent(let reason): return reason
            }
        }
    }
}
