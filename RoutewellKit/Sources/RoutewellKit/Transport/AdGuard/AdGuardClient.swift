import Foundation

/// `control/status` fields Routewell reads. Every field is optional: a
/// missing or differently-typed field yields `nil`, never a thrown error.
public struct AdGuardStatusResponse: Sendable, Equatable {
    public var version: String?
    public var running: Bool?
    public var protectionEnabled: Bool?
    public var protectionDisabledDurationMilliseconds: Int?
    public var dnsAddresses: [String] = []

    public init(
        version: String? = nil,
        running: Bool? = nil,
        protectionEnabled: Bool? = nil,
        protectionDisabledDurationMilliseconds: Int? = nil,
        dnsAddresses: [String] = []
    ) {
        self.version = version
        self.running = running
        self.protectionEnabled = protectionEnabled
        self.protectionDisabledDurationMilliseconds = protectionDisabledDurationMilliseconds
        self.dnsAddresses = dnsAddresses
    }
}

/// `control/stats` fields Routewell reads. AdGuard's own stats window is
/// configurable on the router side; the field names below are approximate —
/// AdGuard Home may rename or rescale them across versions.
public struct AdGuardStatsResponse: Sendable, Equatable {
    public var queries: Int?
    public var blocked: Int?
    public var timeUnits: String?

    public init(queries: Int? = nil, blocked: Int? = nil, timeUnits: String? = nil) {
        self.queries = queries
        self.blocked = blocked
        self.timeUnits = timeUnits
    }
}

public enum AdGuardClientError: Error, Equatable, Sendable {
    case transport(TransportError)
    case unauthorized(Int)
    case httpStatus(Int)
    case malformedResponse
    case credentialUnavailable
}

/// Talks to AdGuard Home's own HTTP API (default port 3000), never to the
/// router's `/rpc` endpoint. Every request is pinned to `baseURL`'s
/// scheme/host/port — only the path varies.
public actor AdGuardClient {
    private let baseURL: URL
    private let credentials: any AdGuardCredentialProvider
    private let transport: any HTTPTransport
    private let limits: HTTPRequestLimits
    private let log: SessionEventLog?

    public init(
        baseURL: URL,
        credentials: any AdGuardCredentialProvider,
        transport: any HTTPTransport,
        limits: HTTPRequestLimits = .init(),
        log: SessionEventLog? = nil
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
        self.limits = limits
        self.log = log
    }

    public func status() async throws -> AdGuardStatusResponse {
        let json = try await get(path: "control/status", method: "status")
        var response = AdGuardStatusResponse()
        response.version = json["version"]?.string
        response.running = json["running"]?.bool
        response.protectionEnabled = json["protection_enabled"]?.bool
        response.protectionDisabledDurationMilliseconds = json["protection_disabled_duration"]?.int
        response.dnsAddresses = json["dns_addresses"]?.array?.compactMap(\.string) ?? []
        return response
    }

    public func stats() async throws -> AdGuardStatsResponse {
        let json = try await get(path: "control/stats", method: "stats")
        var response = AdGuardStatsResponse()
        response.queries = json["num_dns_queries"]?.int
        response.blocked = json["num_blocked_filtering"]?.int
        response.timeUnits = json["time_units"]?.string
        return response
    }

    public static func adGuardStatus(status: AdGuardStatusResponse?, stats: AdGuardStatsResponse?, now: Date) -> AdGuardStatus {
        var result = AdGuardStatus()
        result.reachability = status != nil ? .connected : .unknown
        result.version = status?.version

        switch status?.protectionEnabled {
        case true:
            result.protection = .enabled
        case false:
            if let duration = status?.protectionDisabledDurationMilliseconds, duration > 0 {
                result.protection = .paused(until: now.addingTimeInterval(TimeInterval(duration) / 1000))
            } else {
                result.protection = .disabled
            }
        case nil:
            result.protection = .unknown
        }

        result.queriesToday = stats?.queries
        result.blockedToday = stats?.blocked
        return result
    }

    // MARK: - Request plumbing

    private func get(path: String, method: String) async throws -> JSONValue {
        try await get(path: path, method: method, retried: false)
    }

    private func get(path: String, method: String, retried: Bool) async throws -> JSONValue {
        let headers: [String: String]
        do {
            headers = try await credentials.authorizationHeaders()
        } catch {
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(method) failed credentialUnavailable"))
            throw AdGuardClientError.credentialUnavailable
        }

        let url = requestURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request, limits: limits)
        } catch let error as TransportError {
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(method) failed transport"))
            throw AdGuardClientError.transport(error)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            if !retried, await credentials.handleUnauthorized() {
                return try await get(path: path, method: method, retried: true)
            }
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(method) failed unauthorized"))
            throw AdGuardClientError.unauthorized(response.statusCode)
        }
        guard response.statusCode == 200 else {
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(method) failed httpStatus \(response.statusCode)"))
            throw AdGuardClientError.httpStatus(response.statusCode)
        }

        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), json.object != nil else {
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(method) failed malformedResponse"))
            throw AdGuardClientError.malformedResponse
        }

        await log?.record(LogEvent(level: .info, kind: .refresh, message: "adguard \(method) ok \(data.count) bytes"))
        return json
    }

    private func requestURL(path: String) -> URL {
        let url = baseURL.appendingPathComponent(path)
        precondition(url.host == baseURL.host && url.port == baseURL.port,
                     "AdGuardClient must never leave baseURL's host/port")
        return url
    }
}
