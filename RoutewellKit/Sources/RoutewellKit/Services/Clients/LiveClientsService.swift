import Foundation

/// Live Clients service: RPC `clients get_list` is the primary source; AdGuard
/// Home `control/clients` and `control/stats` are read at the same time and
/// joined. The area fails only when the router list fails (decision 9).
public actor LiveClientsService: ClientsService {
    private let rpc: GLiNetRPCClient
    private let adGuard: AdGuardClient?
    private let clock: @Sendable () -> Date

    public init(rpc: GLiNetRPCClient, adGuard: AdGuardClient?, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.rpc = rpc
        self.adGuard = adGuard
        self.clock = clock
    }

    public func probe() async -> Capability {
        do {
            _ = try await rpc.call(.clientList)
            return Capability(.supported, evidence: .successfulResponse, observedAt: clock())
        } catch GLiNetRPCError.methodNotFound {
            return Capability(.unsupported, evidence: .methodNotFound(method: "clients.get_list"), observedAt: clock())
        } catch {
            return Capability()
        }
    }

    public func inventory() async throws -> ClientInventoryResult {
        let attemptedAt = clock()
        async let list = rpc.checkedCall(.clientList)
        async let directory = fetchAdGuard(.clients)
        async let stats = fetchAdGuard(.stats)
        let listResult = try await list
        let directoryResult = try await directory
        let statsResult = try await stats

        let listJSON: JSONValue
        switch listResult {
        case .failure(.methodNotFound):
            return ClientInventoryResult(
                area: .failure(.unavailable, attemptedAt: attemptedAt),
                capability: Capability(.unsupported, evidence: .methodNotFound(method: "clients.get_list"), observedAt: attemptedAt)
            )
        case .failure(let error):
            return ClientInventoryResult(area: .failure(LiveRouterBackend.category(for: error), attemptedAt: attemptedAt), capability: Capability())
        case .success(let json):
            listJSON = json
        }
        guard let parsed = GLiNetClientListParser.parse(listJSON) else {
            return ClientInventoryResult(area: .failure(.malformedResponse, attemptedAt: attemptedAt), capability: Capability())
        }

        let parsedDirectory = directoryResult?.flatMap { json in
            AdGuardClientsParser.parse(json).map(Result.success) ?? .failure(.malformedResponse)
        }
        let parsedStats = statsResult?.flatMap { json in
            AdGuardStatsParser.topClientQueries(json).map(Result.success) ?? .failure(.malformedResponse)
        }
        let enrichment = Self.enrichment(directory: parsedDirectory, stats: parsedStats)
        let clients = ClientMerge.merge(
            router: parsed.entries,
            adGuardDirectory: try? parsedDirectory?.get(),
            topClientQueries: try? parsedStats?.get()
        )
        let inventory = ClientInventory(clients: clients, enrichment: enrichment, skippedEntries: parsed.skippedEntries)
        return ClientInventoryResult(
            area: .success(inventory, observedAt: attemptedAt, source: .routerRPC),
            capability: Capability(.supported, evidence: .successfulResponse, observedAt: attemptedAt)
        )
    }

    static func enrichment(
        directory: Result<AdGuardClientsParser.Directory, RefreshFailureCategory>?,
        stats: Result<[String: Int], RefreshFailureCategory>?
    ) -> ClientEnrichment {
        switch (directory, stats) {
        case (nil, _), (_, nil): return .notConfigured
        case (.success, .success): return .joined
        case (.failure(let category), .success), (.success, .failure(let category)): return .partial(category)
        case (.failure(let category), .failure): return .failed(category)
        }
    }

    /// `nil` when no AdGuard Home instance is configured for the profile.
    private func fetchAdGuard(_ path: AdGuardReadPath) async throws -> Result<JSONValue, RefreshFailureCategory>? {
        guard let adGuard else { return nil }
        return try await LiveRouterBackend.adGuardResult { try await adGuard.read(path) }
    }
}
