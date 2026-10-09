import Foundation

/// `control/status` fields Routewell reads. Every field is optional: a
/// missing or differently-typed field yields `nil`, never a thrown error.
public struct AdGuardStatusResponse: Sendable, Equatable, Codable {
    public var version: String?
    public var running: Bool?
    public var protectionEnabled: Bool?
    public var protectionDisabledDurationMilliseconds: Int?
    public var dnsAddresses: [String] = []
    /// `dns_port` `[verified live]`: 3053 on 4.9.1, behind the router's dnsmasq.
    public var dnsPort: Int?
    /// `start_time` `[verified live]`: when AdGuard Home started, in
    /// milliseconds since 1970 (fractional on 4.9.1).
    public var startTime: Date?

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

/// Read-only AdGuard Home paths a feature service may fetch as raw JSON for
/// its own parser.
public enum AdGuardReadPath: String, Sendable, CaseIterable {
    case clients = "control/clients"
    case stats = "control/stats"
    // Chunk 17: the Overview tab.
    case statsConfig = "control/stats/config"
    case safeBrowsingStatus = "control/safebrowsing/status"
    case parentalStatus = "control/parental/status"
    case safeSearchStatus = "control/safesearch/status"
    case filteringStatus = "control/filtering/status"

    /// The name in the session log.
    var logName: String {
        switch self {
        case .clients: "clients"
        case .stats: "stats"
        case .statsConfig: "stats config"
        case .safeBrowsingStatus: "safebrowsing status"
        case .parentalStatus: "parental status"
        case .safeSearchStatus: "safesearch status"
        case .filteringStatus: "filtering status"
        }
    }

    public static func status(of feature: AdGuardFeature) -> AdGuardReadPath {
        switch feature {
        case .safeBrowsing: .safeBrowsingStatus
        case .parental: .parentalStatus
        case .safeSearch: .safeSearchStatus
        }
    }
}

/// The AdGuard Home writes Routewell sends (architecture 04). Every other
/// path is out of reach of `AdGuardClient.write`.
public enum AdGuardWrite: Sendable, Equatable {
    /// `POST control/protection {"enabled", "duration"}`.
    case protection(enabled: Bool, durationMilliseconds: Int)
    /// `POST control/safebrowsing/enable` or `.../disable`, no body; the same
    /// for Parental.
    case feature(AdGuardFeature, enabled: Bool)
    /// `PUT control/safesearch/settings`: the status object as read, with
    /// `enabled` replaced, so the engine flags go back unchanged.
    case safeSearchSettings(JSONValue)
    /// `POST control/filtering/config {"enabled", "interval"}`: AdGuard
    /// Home's "Filter requests" (chunk 17, user request). The interval goes
    /// back as read. The web UI sends this shape (user, 2026-10-08).
    case filteringConfig(enabled: Bool, intervalHours: Int)
    /// `POST control/filtering/set_rules {"rules": [...]}`: the whole custom
    /// rules list (chunk 18, Block or Unblock Domain) `[assumed]`.
    case setRules([String])

    var httpMethod: String {
        if case .safeSearchSettings = self { return "PUT" }
        return "POST"
    }

    var path: String {
        switch self {
        case .protection: "control/protection"
        case .feature(let feature, let enabled):
            switch feature {
            case .safeBrowsing: enabled ? "control/safebrowsing/enable" : "control/safebrowsing/disable"
            case .parental: enabled ? "control/parental/enable" : "control/parental/disable"
            case .safeSearch: "control/safesearch/settings"
            }
        case .safeSearchSettings: "control/safesearch/settings"
        case .filteringConfig: "control/filtering/config"
        case .setRules: "control/filtering/set_rules"
        }
    }

    var body: JSONValue? {
        switch self {
        case .protection(let enabled, let duration):
            .object(["enabled": .bool(enabled), "duration": .number(Double(duration))])
        case .feature: nil
        case .safeSearchSettings(let settings): settings
        case .filteringConfig(let enabled, let interval):
            .object(["enabled": .bool(enabled), "interval": .number(Double(interval))])
        case .setRules(let rules):
            .object(["rules": .array(rules.map(JSONValue.string))])
        }
    }

    var logName: String {
        switch self {
        case .protection: "setProtection"
        case .feature(let feature, _): "set \(feature.rawValue)"
        case .safeSearchSettings: "set safeSearch"
        case .filteringConfig: "set filtering"
        case .setRules: "set rules"
        }
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
        response.dnsPort = json["dns_port"]?.int
        response.startTime = json["start_time"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        return response
    }

    public func read(_ path: AdGuardReadPath) async throws -> JSONValue {
        try await get(path: path.rawValue, method: path.logName)
    }

    /// `GET control/stats?recent=<ms>` (chunk 17). `recent` is the lookback,
    /// a whole number of hours, at most the stats retention; `nil` is the
    /// plain read. A version without `recent` may ignore it or answer 400.
    public func stats(recentMilliseconds: Int?) async throws -> JSONValue {
        let query = recentMilliseconds.map { [URLQueryItem(name: "recent", value: String($0))] } ?? []
        return try await get(path: AdGuardReadPath.stats.rawValue, query: query, method: "stats", retried: false)
    }

    /// `GET control/querylog?limit=<N>[&search=<text>]`: one bounded page of
    /// the newest entries. `search` narrows the page on the server
    /// `[assumed]`; callers still filter the result exactly.
    public func queryLog(search: String?, limit: Int) async throws -> JSONValue {
        try await queryLog(QueryLogQuery(search: search, limit: limit))
    }

    /// `GET control/querylog?limit=<N>[&older_than=…][&search=…][&response_status=…]`
    /// (chunk 18). `all` is not sent.
    public func queryLog(_ request: QueryLogQuery) async throws -> JSONValue {
        var query = [URLQueryItem(name: "limit", value: String(request.limit))]
        if let olderThan = request.olderThan { query.append(URLQueryItem(name: "older_than", value: olderThan)) }
        if let search = request.search { query.append(URLQueryItem(name: "search", value: search)) }
        if request.status != .all { query.append(URLQueryItem(name: "response_status", value: request.status.responseStatus)) }
        return try await get(path: "control/querylog", query: query, method: "querylog", retried: false)
    }

    /// `path` may end in a query (`control/stats?recent=86400000`). Each
    /// name and value must pass `FixtureRecordingPlan.isSafeQueryValue`.
    public func recordRead(path: String) async -> JSONValue {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let route = String(parts[0])
        var query: [URLQueryItem] = []
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard field.count == 2, FixtureRecordingPlan.isSafeQueryValue(name: field[0], value: field[1]) else {
                    return .object(["error": .object(["category": .string("invalid path")])])
                }
                query.append(URLQueryItem(name: field[0], value: field[1]))
            }
        }
        guard route.hasPrefix("control/"), !route.contains("..") else {
            return .object(["error": .object(["category": .string("invalid path")])])
        }
        do { return try await get(path: route, query: query, method: "fixture", retried: false) }
        catch AdGuardClientError.unauthorized {
            return .object(["error": .object(["category": .string("authentication")])])
        } catch AdGuardClientError.httpStatus(let status) {
            return .object(["error": .object(["status": .number(Double(status))])])
        } catch {
            return .object(["error": .object(["category": .string("unavailable")])])
        }
    }

    /// `POST control/protection`: `write(.protection(...))`.
    public func setProtection(enabled: Bool, durationMilliseconds: Int) async throws {
        try await write(.protection(enabled: enabled, durationMilliseconds: durationMilliseconds))
    }

    /// One AdGuard Home write. Dispatches at most once per call: a 401/403
    /// that arrives before the body is accepted is re-authenticated and
    /// re-dispatched exactly once, which still counts as the single
    /// accepted attempt (the first response was a rejection, not an
    /// ambiguous outcome). Any other failure — transport error, timeout,
    /// non-2xx after the retry — is surfaced as a thrown error; the caller
    /// (the mutation executor) treats that as "dispatched, outcome
    /// unknown" rather than replaying the write.
    public func write(_ write: AdGuardWrite) async throws {
        try await send(write, previousUnauthorizedStatus: nil)
    }

    /// `previousUnauthorizedStatus` is non-nil only on the single retry
    /// after a 401/403: at that point a request has already reached the
    /// server and was rejected. If re-authenticating (or just re-reading
    /// the credential for the retry's headers) fails here, that is not the
    /// same as "nothing was ever sent" — surface `.unauthorized` (the
    /// original rejection status) rather than `.credentialUnavailable`, so
    /// callers know a dispatch already happened.
    private func send(_ write: AdGuardWrite, previousUnauthorizedStatus: Int?) async throws {
        let name = write.logName
        let headers: [String: String]
        do {
            headers = try await credentials.authorizationHeaders()
        } catch {
            if let previousUnauthorizedStatus {
                await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(name) retry credential fetch failed"))
                throw AdGuardClientError.unauthorized(previousUnauthorizedStatus)
            }
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(name) failed credentialUnavailable"))
            throw AdGuardClientError.credentialUnavailable
        }

        var request = URLRequest(url: requestURL(path: write.path))
        request.httpMethod = write.httpMethod
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let body = write.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
        }

        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.send(request, limits: limits)
        } catch let error as TransportError {
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(name) failed transport"))
            throw AdGuardClientError.transport(error)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            if previousUnauthorizedStatus == nil, await credentials.handleUnauthorized() {
                return try await send(write, previousUnauthorizedStatus: response.statusCode)
            }
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(name) failed unauthorized"))
            throw AdGuardClientError.unauthorized(response.statusCode)
        }
        guard (200...204).contains(response.statusCode) else {
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(name) failed httpStatus \(response.statusCode)"))
            throw AdGuardClientError.httpStatus(response.statusCode)
        }

        await log?.record(LogEvent(level: .info, kind: .refresh, message: "adguard \(name) ok"))
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
        result.running = status?.running.map(Observed.value) ?? .unknown
        result.dnsPort = status?.dnsPort

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
        try await get(path: path, query: [], method: method, retried: false)
    }

    private func get(path: String, query: [URLQueryItem], method: String, retried: Bool) async throws -> JSONValue {
        let headers: [String: String]
        do {
            headers = try await credentials.authorizationHeaders()
        } catch {
            await log?.record(LogEvent(level: .warning, kind: .refresh, message: "adguard \(method) failed credentialUnavailable"))
            throw AdGuardClientError.credentialUnavailable
        }

        let url = requestURL(path: path, query: query)
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
                return try await get(path: path, query: query, method: method, retried: true)
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

    private func requestURL(path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty {
            url.append(queryItems: query)
            // `URL` leaves `+` as is, and AdGuard Home reads it as a space.
            // A time such as `older_than=…+01:00` needs `%2B`.
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let encoded = components.percentEncodedQuery, encoded.contains("+") {
                components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
                url = components.url ?? url
            }
        }
        precondition(url.host == baseURL.host && url.port == baseURL.port,
                     "AdGuardClient must never leave baseURL's host/port")
        return url
    }
}
