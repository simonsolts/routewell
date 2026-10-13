import Foundation

/// Live Router service: RPC `sqm get_config` for SQM, and `upgrade
/// check_firmware_online` on demand. Everything else on the Router screen
/// comes from the Overview areas' shared reads.
public actor LiveRouterService: RouterService {
    private let rpc: GLiNetRPCClient
    private let clock: @Sendable () -> Date

    public init(rpc: GLiNetRPCClient, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.rpc = rpc
        self.clock = clock
    }

    static let sqmConfig = GLiNetRPCCall(object: "sqm", method: "get_config", params: .object([:]))
    static let firmwareCheck = GLiNetRPCCall(object: "upgrade", method: "check_firmware_online", params: .object([:]))

    public func probe() async -> Capability {
        switch try? await rpc.checkedCall(Self.sqmConfig) {
        case .success?: Capability(.supported, evidence: .successfulResponse, observedAt: clock())
        case .failure(.methodNotFound)?: Capability(.unsupported, evidence: .methodNotFound(method: "sqm.get_config"), observedAt: clock())
        default: Capability()
        }
    }

    public func details() async throws -> RouterDetailsResult {
        let attemptedAt = clock()
        let sqmResult = try await rpc.checkedCall(Self.sqmConfig)

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
        return RouterDetailsResult(sqm: sqmArea, sqmCapability: capability)
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
