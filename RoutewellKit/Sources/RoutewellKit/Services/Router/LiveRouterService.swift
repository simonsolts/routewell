import Foundation

/// Live Router service: RPC `wifi get_config` and `wifi get_status` for the
/// Wi-Fi segment, `sqm get_config` for SQM, and `upgrade
/// check_firmware_online` on demand. Everything else on the Router screen
/// comes from the Overview areas' shared reads.
public actor LiveRouterService: RouterService {
    private let rpc: GLiNetRPCClient
    private let clock: @Sendable () -> Date

    public init(rpc: GLiNetRPCClient, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.rpc = rpc
        self.clock = clock
    }

    static let wifiConfig = GLiNetRPCCall(object: "wifi", method: "get_config", params: .object([:]))
    static let wifiStatus = GLiNetRPCCall(object: "wifi", method: "get_status", params: .object([:]))
    static let sqmConfig = GLiNetRPCCall(object: "sqm", method: "get_config", params: .object([:]))
    static let firmwareCheck = GLiNetRPCCall(object: "upgrade", method: "check_firmware_online", params: .object([:]))

    public func probe() async -> Capability {
        switch try? await rpc.checkedCall(Self.wifiConfig) {
        case .success?: Capability(.supported, evidence: .successfulResponse, observedAt: clock())
        case .failure(.methodNotFound)?: Capability(.unsupported, evidence: .methodNotFound(method: "wifi.get_config"), observedAt: clock())
        default: Capability()
        }
    }

    public func details() async throws -> RouterDetailsResult {
        let attemptedAt = clock()
        async let config = rpc.checkedCall(Self.wifiConfig)
        async let status = rpc.checkedCall(Self.wifiStatus)
        async let sqm = rpc.checkedCall(Self.sqmConfig)
        let configResult = try await config
        let statusResult = try await status
        let sqmResult = try await sqm

        let wireless: AreaRefreshResult<WirelessStatus>
        switch configResult {
        case .success(let json):
            // A failed `get_status` only loses the current channel.
            if let parsed = WirelessParser.parse(config: json, status: try? statusResult.get()) {
                wireless = .success(parsed, observedAt: attemptedAt, source: .routerRPC)
            } else {
                wireless = .failure(.malformedResponse, attemptedAt: attemptedAt)
            }
        case .failure(let error):
            wireless = .failure(FailureMapping.category(for: error), attemptedAt: attemptedAt)
        }

        let sqmArea: AreaRefreshResult<SQMConfiguration>
        let capability: Capability
        switch sqmResult {
        case .success(let json):
            if let parsed = SQMParser.parse(json) {
                sqmArea = .success(parsed, observedAt: attemptedAt, source: .routerRPC)
                capability = Capability(.supported, evidence: .successfulResponse, observedAt: attemptedAt)
            } else {
                sqmArea = .failure(.malformedResponse, attemptedAt: attemptedAt)
                capability = Capability()
            }
        case .failure(.methodNotFound):
            sqmArea = .failure(.unavailable, attemptedAt: attemptedAt)
            capability = Capability(.unsupported, evidence: .methodNotFound(method: "sqm.get_config"), observedAt: attemptedAt)
        case .failure(let error):
            sqmArea = .failure(FailureMapping.category(for: error), attemptedAt: attemptedAt)
            capability = Capability()
        }
        return RouterDetailsResult(wireless: wireless, sqm: sqmArea, sqmCapability: capability)
    }

    public func checkFirmware() async throws -> FirmwareCheck {
        let result = try await rpc.checkedCall(Self.firmwareCheck)
        let now = clock()
        switch result {
        case .success(let json):
            return FirmwareCheckParser.parse(json, at: now)
        case .failure(.methodNotFound):
            return FirmwareCheck(status: .unableToCheck(.notSupported), checkedAt: now)
        case .failure(let error):
            return FirmwareCheck(status: .unableToCheck(.failed(FailureMapping.category(for: error))), checkedAt: now)
        }
    }
}
