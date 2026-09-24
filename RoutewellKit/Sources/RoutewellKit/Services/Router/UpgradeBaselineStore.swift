import Foundation

/// The observed router state a firmware upgrade might change. Every field is
/// optional: a value Routewell did not observe is left out, never guessed.
public struct RouterStateSummary: Sendable, Equatable, Codable {
    public var model: String?
    public var hostname: String?
    public var firmware: String?
    public var openWrt: String?
    public var kernel: String?
    public var architecture: String?
    public var lanAddress: String?
    public var wanProtocol: String?
    public var internetConnected: Bool?
    public var adGuardVersion: String?
    public var adGuardRunning: Bool?
    public var sqmEnabled: Bool?
    public var wifiRadios: Int?
    public var wifiNetworksEnabled: Int?
    public var clientsOnline: Int?

    public init() {}

    public static func capture(_ snapshot: OverviewSnapshot, wireless: WirelessStatus?) -> RouterStateSummary {
        var state = RouterStateSummary()
        state.model = snapshot.router.model
        state.hostname = snapshot.router.hostname
        state.firmware = snapshot.router.firmware
        state.openWrt = snapshot.router.openWrtVersion
        state.kernel = snapshot.router.kernelVersion
        state.architecture = snapshot.router.architecture
        state.lanAddress = snapshot.router.lanAddress
        state.wanProtocol = snapshot.internet.wanProtocol
        switch snapshot.internet.reachability {
        case .connected: state.internetConnected = true
        case .unreachable: state.internetConnected = false
        case .unknown: break
        }
        state.adGuardVersion = snapshot.adGuard.version
        if case .value(let running) = snapshot.adGuard.running { state.adGuardRunning = running }
        if case .value(let enabled) = snapshot.router.sqmEnabled { state.sqmEnabled = enabled }
        if let wireless {
            state.wifiRadios = wireless.radios.count
            state.wifiNetworksEnabled = wireless.enabledNetworkCount
        }
        if case .value(let count) = snapshot.clients.activeCount { state.clientsOnline = count }
        return state
    }

    /// Each field as comparable text, in a fixed order.
    public var fields: [(BaselineField, String?)] {
        [(.model, model), (.hostname, hostname), (.firmware, firmware), (.openWrt, openWrt), (.kernel, kernel),
         (.architecture, architecture), (.lanAddress, lanAddress), (.wanProtocol, wanProtocol),
         (.internetConnected, internetConnected.map(String.init)), (.adGuardVersion, adGuardVersion),
         (.adGuardRunning, adGuardRunning.map(String.init)), (.sqmEnabled, sqmEnabled.map(String.init)),
         (.wifiRadios, wifiRadios.map(String.init)), (.wifiNetworksEnabled, wifiNetworksEnabled.map(String.init)),
         (.clientsOnline, clientsOnline.map(String.init))]
    }
}

public enum BaselineField: String, Sendable, Equatable, Codable, CaseIterable {
    case model, hostname, firmware, openWrt, kernel, architecture, lanAddress, wanProtocol, internetConnected
    case adGuardVersion, adGuardRunning, sqmEnabled, wifiRadios, wifiNetworksEnabled, clientsOnline
}

public struct BaselineDifference: Sendable, Equatable, Codable {
    public let field: BaselineField
    public let before: String?
    public let after: String?
}

public struct UpgradeBaseline: Sendable, Equatable, Codable {
    public let capturedAt: Date
    public let state: RouterStateSummary

    public init(capturedAt: Date, state: RouterStateSummary) {
        self.capturedAt = capturedAt
        self.state = state
    }
}

public struct PostUpgradeCheck: Sendable, Equatable, Codable {
    public let ranAt: Date
    public let baselineCapturedAt: Date
    /// Fields observed both before and after.
    public let comparedFields: Int
    /// Every field whose value changed, appeared, or disappeared.
    public let differences: [BaselineDifference]

    /// Compares the current observed state against the saved baseline.
    public static func compare(_ baseline: UpgradeBaseline, current: RouterStateSummary, at date: Date) -> PostUpgradeCheck {
        let after = Dictionary(uniqueKeysWithValues: current.fields.map { ($0.0, $0.1) })
        var compared = 0
        var differences: [BaselineDifference] = []
        for (field, before) in baseline.state.fields {
            let value = after[field] ?? nil
            if before != nil, value != nil { compared += 1 }
            if before != value { differences.append(BaselineDifference(field: field, before: before, after: value)) }
        }
        return PostUpgradeCheck(ranAt: date, baselineCapturedAt: baseline.capturedAt, comparedFields: compared, differences: differences)
    }
}

/// `snapshots.json`: per router profile, the saved pre-upgrade baseline and
/// the last post-upgrade check. Local only; nothing is written to the router.
public struct UpgradeSnapshots: Sendable, Equatable, Codable {
    public var baselines: [String: UpgradeBaseline] = [:]
    public var checks: [String: PostUpgradeCheck] = [:]
    public init() {}
}

public actor UpgradeBaselineStore {
    private let store: AtomicJSONStore?
    private var state = UpgradeSnapshots()
    private var revision: UInt64 = 0

    public init(store: AtomicJSONStore?, initial: UpgradeSnapshots = .init()) {
        self.store = store
        state = initial
    }

    public func snapshot() -> UpgradeSnapshots { state }

    public func load() async -> LocalStoreLoad {
        guard let store else { return .empty }
        do {
            guard let value = try await store.load(UpgradeSnapshots.self, from: .snapshots) else { return .empty }
            state = value
            return .loaded
        } catch StoreError.corrupt {
            return .recovered
        } catch let error as StoreError {
            return .blocked(error)
        } catch {
            return .blocked(.readFailed)
        }
    }

    /// Saving a new baseline clears the old check, which compared another baseline.
    public func saveBaseline(_ baseline: UpgradeBaseline, for router: String) async -> StoreError? {
        var next = state
        next.baselines[router] = baseline
        next.checks[router] = nil
        return await commit(next)
    }

    public func recordCheck(_ check: PostUpgradeCheck, for router: String) async -> StoreError? {
        var next = state
        next.checks[router] = check
        return await commit(next)
    }

    /// Memory changes only after the file is written, so the screen never
    /// shows a baseline that a relaunch would lose.
    private func commit(_ next: UpgradeSnapshots) async -> StoreError? {
        guard let store else { state = next; return nil }
        revision += 1
        do {
            try await store.save(next, to: .snapshots, revision: revision)
            state = next
            return nil
        } catch let error as StoreError {
            return error
        } catch {
            return .writeFailed
        }
    }
}
