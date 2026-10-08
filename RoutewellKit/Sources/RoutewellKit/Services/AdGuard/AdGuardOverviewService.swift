import Foundation

/// AdGuard Home › Overview's reads (chunk 17), behind
/// `RouterBackend.adGuardOverview`. `nil` without an AdGuard Home connection.
public protocol AdGuardOverviewService: Sendable {
    /// Stats for `range`, the stats retention, the three switches, and the
    /// blocklists. Throws only `CancellationError`; every other failure is
    /// a part of the reading.
    func overview(range: AdGuardStatsRange) async throws -> AdGuardOverviewReading
}

/// Reads the retention first, because `recent` must not exceed it, then the
/// stats for the range. The other reads run alongside.
public struct LiveAdGuardOverviewService: AdGuardOverviewService {
    private let adGuard: AdGuardClient
    private let clock: @Sendable () -> Date

    public init(adGuard: AdGuardClient, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.adGuard = adGuard
        self.clock = clock
    }

    public func overview(range: AdGuardStatsRange) async throws -> AdGuardOverviewReading {
        let observedAt = clock()
        let adGuard = adGuard
        async let config = Self.part { AdGuardStatsConfig.parse(try await adGuard.read(.statsConfig)) }
        async let safeBrowsing = Self.part { try await adGuard.read(.safeBrowsingStatus) }
        async let parental = Self.part { try await adGuard.read(.parentalStatus) }
        async let safeSearch = Self.part { try await adGuard.read(.safeSearchStatus) }
        async let filtering = Self.part { AdGuardFilteringStatus.parse(try await adGuard.read(.filteringStatus)) }

        let statsConfig = try await config
        let retention = try? statsConfig.get().intervalMilliseconds
        let recent = range.recentMilliseconds(retentionMilliseconds: retention)
        var honoured = true
        var stats = try await Self.part { AdGuardStats.parse(try await adGuard.stats(recentMilliseconds: recent)) }
        if let recent {
            switch stats {
            case .failure:
                // A version without `recent` may answer 400: read the plain stats.
                let plain = try await Self.part { AdGuardStats.parse(try await adGuard.stats(recentMilliseconds: nil)) }
                if case .success = plain { stats = plain; honoured = false }
            case .success(let value):
                honoured = value.matches(recentMilliseconds: recent)
            }
        }

        let switches = try await [safeBrowsing, parental, safeSearch]
        let protection: Result<ProtectionOptions, RefreshFailureCategory>
        if switches.allSatisfy({ if case .failure = $0 { true } else { false } }), case .failure(let category) = switches[0] {
            protection = .failure(category)
        } else {
            let enabled = switches.map { try? $0.get()["enabled"]?.bool }
            protection = .success(ProtectionOptions(safeBrowsing: enabled[0] ?? nil, parental: enabled[1] ?? nil, safeSearch: enabled[2] ?? nil))
        }
        return AdGuardOverviewReading(range: range, stats: stats, rangeHonoured: honoured, statsConfig: statsConfig,
                                      protection: protection, filtering: try await filtering, observedAt: observedAt)
    }

    /// One read as a result. Cancellation propagates.
    private static func part<Value: Sendable>(_ read: @Sendable () async throws -> Value) async throws -> Result<Value, RefreshFailureCategory> {
        do {
            return .success(try await read())
        } catch let error as AdGuardClientError {
            try LiveRouterBackend.rethrowIfCancelled(error)
            return .failure(LiveRouterBackend.category(for: error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.unavailable)
        }
    }
}
