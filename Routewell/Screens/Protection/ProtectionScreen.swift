import SwiftUI
import RoutewellKit
#if DEBUG
import RoutewellMock
#endif

struct ProtectionScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmingDisable = false
    #if DEBUG
    @State private var mockProtectionBehavior: MockRouterBackend.ProtectionBehavior = .succeeds
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                stateCard
                if let outcome = environment.mutation.lastReport?.outcome {
                    outcomeBanner(outcome)
                }
                #if DEBUG
                if model.mode == .mock {
                    mockBehaviorPicker
                }
                #endif
            }
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Disable protection until you enable it again?",
            isPresented: $confirmingDisable
        ) {
            Button("Disable", role: .destructive) { submit(.disable) }
        }
    }

    private var stateCard: some View {
        InsetGroup(title: "Protection") {
            LabelValueRow(label: "Status", value: stateLabel(currentState, capitalized: true))
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Freshness")
                Spacer()
                Text(freshnessSubtitle).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            HStack(spacing: 12) {
                Button("Enable") { submit(.enable) }
                    .disabled(inFlight)
                Button("Disable…") { confirmingDisable = true }
                    .disabled(inFlight)
                Menu("Pause") {
                    Button("5 Minutes") { submit(.pause(.seconds(5 * 60))) }
                    Button("30 Minutes") { submit(.pause(.seconds(30 * 60))) }
                    Button("1 Hour") { submit(.pause(.seconds(60 * 60))) }
                    Button("Until Tomorrow 6:00 AM") { submit(.pause(pauseUntilTomorrowSix())) }
                }
                .disabled(inFlight)
                .frame(maxWidth: 120)
                if inFlight {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
                Spacer()
            }.padding(12)
        }
    }

    private func outcomeBanner(_ outcome: MutationOutcome<ProtectionState>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(bannerText(for: outcome)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if case .unknownAfterDispatch = outcome {
                Button("Refresh") { environment.refresh.refreshNow() }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }

    #if DEBUG
    private var mockBehaviorPicker: some View {
        InsetGroup(title: "Mock behavior") {
            Picker("Mock behavior", selection: $mockProtectionBehavior) {
                ForEach(MockRouterBackend.ProtectionBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.rawValue).tag(behavior)
                }
            }
            .labelsHidden()
            .padding(12)
            .onChange(of: mockProtectionBehavior) { _, newValue in
                environment.setMockProtectionBehavior(newValue)
            }
        }
    }
    #endif

    private var currentState: ProtectionState { model.snapshot?.adGuard.protection ?? .unknown }
    private var inFlight: Bool { environment.mutation.inFlight != nil }

    private var freshnessSubtitle: String {
        let freshness = model.freshness[.adGuard] ?? Freshness()
        if freshness.isRefreshing { return String(localized: "Refreshing…") }
        if let failure = freshness.failure {
            let message = failure.failureCategory.message
            guard let lastSuccess = freshness.lastSuccess else { return message }
            return "\(message) Last data \(relative(lastSuccess))."
        }
        guard let lastSuccess = freshness.lastSuccess else { return String(localized: "Never loaded") }
        return relative(lastSuccess)
    }

    private func relative(_ date: Date) -> String {
        if abs(model.evaluatedAt.timeIntervalSince(date)) < 1 { return String(localized: "Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: model.evaluatedAt)
    }

    private func submit(_ intent: ProtectionIntent) {
        environment.mutation.setProtection(intent)
    }

    private func stateLabel(_ state: ProtectionState, capitalized: Bool) -> String {
        Self.stateLabel(state, capitalized: capitalized)
    }

    static func stateLabel(_ state: ProtectionState, capitalized: Bool) -> String {
        let word: String
        switch state {
        case .enabled: word = "enabled"
        case .disabled: word = "disabled"
        case .paused(let until): word = "paused until \(until.formatted(date: .omitted, time: .shortened))"
        case .unknown: word = "unknown"
        }
        guard capitalized, let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst()
    }

    private func bannerText(for outcome: MutationOutcome<ProtectionState>) -> String {
        Self.bannerText(for: outcome)
    }

    /// Exact banner text per outcome. See `plan-10.md` Task 10.3 for the
    /// required strings.
    static func bannerText(for outcome: MutationOutcome<ProtectionState>) -> String {
        switch outcome {
        case .verifiedSuccess(let state):
            return "Protection is now \(stateLabel(state, capitalized: false))."
        case .verifiedMismatch(_, let actual):
            return "The router did not apply the change. Protection is still \(stateLabel(actual, capitalized: false))."
        case .verifiedRecovery:
            return "The change did not apply. Routewell restored the previous setting."
        case .recoveryFailed:
            return "The change did not apply and the previous setting could not be restored. Check AdGuard Home."
        case .conflictingExternalEdit:
            return "Protection changed from somewhere else. Routewell made no further change."
        case .unknownAfterDispatch:
            return "The router did not answer in time. The change may have applied. Refresh to check."
        case .rejected(let rejection):
            switch rejection {
            case .gateBusy: return "Another change is still running."
            case .capabilityUnavailable: return "AdGuard Home is not configured for this router."
            case .staleSession: return "The router changed during the operation. Refresh to check."
            case .preconditionFailed(let reason), .invalidIntent(let reason): return reason
            }
        }
    }

    /// Next local 06:00, capped at 24 hours ahead.
    private func pauseUntilTomorrowSix(now: Date = Date()) -> Duration {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 6
        components.minute = 0
        components.second = 0
        var target = calendar.date(from: components) ?? now.addingTimeInterval(24 * 60 * 60)
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target.addingTimeInterval(24 * 60 * 60)
        }
        let seconds = min(target.timeIntervalSince(now), 24 * 60 * 60)
        return .seconds(Int(seconds.rounded()))
    }
}
