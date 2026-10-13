import Foundation

/// The live `WiFiService`: RPC `wifi get_config`, `get_status`,
/// `get_mlo_config`, and `vlan_subnet get_subnets` for the snapshot, and
/// three fixed SSH reads for the stations and the UCI-only options.
public actor LiveWiFiService: WiFiService {
    private let rpc: GLiNetRPCClient
    private let runner: (any SSHCommandRunning)?
    private let clock: @Sendable () -> Date

    /// 256 KiB covers a station dump of many devices.
    static let limits = ProcessLimits(deadline: .seconds(20), maxOutputBytes: 256 * 1024)

    public init(rpc: GLiNetRPCClient, runner: (any SSHCommandRunning)?, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.rpc = rpc
        self.runner = runner
        self.clock = clock
    }

    static let config = GLiNetRPCCall(object: "wifi", method: "get_config", params: .object([:]))
    static let status = GLiNetRPCCall(object: "wifi", method: "get_status", params: .object([:]))
    static let mlo = GLiNetRPCCall(object: "wifi", method: "get_mlo_config", params: .object([:]))
    static let subnets = GLiNetRPCCall(object: "vlan_subnet", method: "get_subnets", params: .object([:]))

    public func probe() async -> Capability {
        switch try? await rpc.checkedCall(Self.config) {
        case .success?: Capability(.supported, evidence: .successfulResponse, observedAt: clock())
        case .failure(.methodNotFound)?: Capability(.unsupported, evidence: .methodNotFound(method: "wifi.get_config"), observedAt: clock())
        default: Capability()
        }
    }

    public func snapshot() async throws -> WiFiSnapshotResult {
        let attemptedAt = clock()
        async let config = rpc.checkedCall(Self.config)
        async let status = rpc.checkedCall(Self.status)
        async let mlo = rpc.checkedCall(Self.mlo)
        async let subnets = rpc.checkedCall(Self.subnets)
        let configResult = try await config
        let statusResult = try await status
        let mloResult = try await mlo
        let subnetsResult = try await subnets

        switch configResult {
        case .failure(.methodNotFound):
            return WiFiSnapshotResult(area: .failure(.unavailable, attemptedAt: attemptedAt),
                                      capability: Capability(.unsupported, evidence: .methodNotFound(method: "wifi.get_config"), observedAt: attemptedAt))
        case .failure(let error):
            return WiFiSnapshotResult(area: .failure(FailureMapping.category(for: error), attemptedAt: attemptedAt), capability: Capability())
        case .success(let json):
            // A failed `get_status` only loses the current channel and state.
            guard let wireless = WirelessParser.parse(config: json, status: try? statusResult.get()) else {
                return WiFiSnapshotResult(area: .failure(.malformedResponse, attemptedAt: attemptedAt), capability: Capability())
            }
            let snapshot = WiFiSnapshot(
                wireless: .success(wireless),
                mlo: Self.part(mloResult, MLOParser.parse),
                subnets: Self.part(subnetsResult, SubnetParser.parse))
            return WiFiSnapshotResult(area: .success(snapshot, observedAt: attemptedAt, source: .routerRPC),
                                      capability: Capability(.supported, evidence: .successfulResponse, observedAt: attemptedAt))
        }
    }

    private static func part<Value>(_ result: Result<JSONValue, GLiNetRPCError>, _ parse: (JSONValue) -> Value?) -> Result<Value, RefreshFailureCategory> {
        switch result {
        case .success(let json): parse(json).map { .success($0) } ?? .failure(.malformedResponse)
        case .failure(let error): .failure(FailureMapping.category(for: error))
        }
    }

    public func air() async throws -> AreaRefreshResult<WiFiAir> {
        let attemptedAt = clock()
        guard let runner else { return .failure(.unavailable, attemptedAt: attemptedAt) }
        let interfaces: [WiFiInterface]
        switch try await runner.read(.wifiInterfaces, limits: Self.limits) {
        case .failure(let failure): return .failure(failure.category, attemptedAt: attemptedAt)
        case .success(let output): interfaces = WiFiInterfaceParser.parse(output.stdout)
        }
        var air = WiFiAir(interfaces: interfaces)
        if interfaces.isEmpty {
            air.stations = []
        } else if case .success(let output) = try await runner.read(.wifiStations(interfaces.map(\.name)), limits: Self.limits) {
            air.stations = StationDumpParser.parse(output.stdout, interfaces: interfaces)
        }
        if case .success(let output) = try await runner.read(.wifiRadioOptions, limits: Self.limits) {
            air.sections = WirelessOptionsParser.parse(output.stdout)
        }
        return .success(air, observedAt: attemptedAt, source: .routerSSH)
    }
}
