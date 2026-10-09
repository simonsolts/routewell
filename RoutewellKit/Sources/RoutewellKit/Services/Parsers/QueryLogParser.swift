import Foundation

/// `GET control/querylog`: `{"oldest": ISO-8601, "data": [...]}`, newest
/// first. The entry fields are `[verified live]` on AdGuard Home v1.0.0-b.1
/// (chunk 18 recording). Entries that are not objects are skipped; missing
/// fields stay unknown.
public enum QueryLogParser {
    /// `nil` when the payload has no `data` array (a malformed reply). A
    /// `null` list reads as empty.
    public static func parse(_ json: JSONValue, limit: Int) -> QueryLogPage? {
        let list: [JSONValue]
        switch json["data"] {
        case .array(let values): list = values
        case .null: list = []
        default: return nil
        }
        let entries = list.compactMap(entry)
        let oldestText = ClientText.meaningful(json["oldest"])
        return QueryLogPage(entries: entries, oldest: oldestText.flatMap(timestamp), oldestText: oldestText, limit: limit)
    }

    static func entry(_ item: JSONValue) -> QueryLogEntry? {
        guard item.object != nil else { return nil }
        let timeText = ClientText.meaningful(item["time"])
        let firstRule = item["rules"]?.array?.first
        return QueryLogEntry(
            time: timeText.flatMap(timestamp),
            timeText: timeText,
            client: ClientText.meaningful(item["client"]),
            clientName: ClientText.meaningful(item["client_info"]?["name"]),
            domain: ClientText.meaningful(item["question"]?["name"]),
            type: ClientText.meaningful(item["question"]?["type"]),
            reason: ClientText.meaningful(item["reason"]),
            upstream: ClientText.meaningful(item["upstream"]),
            elapsedMilliseconds: number(item["elapsedMs"]),
            cached: item["cached"]?.bool,
            // Empty means plain DNS; kept as "" so it is not Unknown.
            clientProtocol: item["client_proto"]?.string?.trimmingCharacters(in: .whitespaces),
            rule: ClientText.meaningful(firstRule?["text"]) ?? ClientText.meaningful(item["rule"]),
            filterID: firstRule?["filter_list_id"]?.int ?? item["filterId"]?.int,
            serviceName: ClientText.meaningful(item["service_name"]),
            responseCode: ClientText.meaningful(item["status"]),
            answers: item["answer"]?.array?.compactMap { ClientText.meaningful($0["value"]) } ?? []
        )
    }

    /// A number, or a number sent as a string (`"0.301155"`).
    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: number
        case .string(let text)?: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// AdGuard Home writes nanosecond fractions (`…:40.610777106Z`). The
    /// fraction is cut to milliseconds before parsing.
    public static func timestamp(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let fractionEnd = text.index(dot, offsetBy: digits.count + 1)
            let kept = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text = String(text[..<dot]) + "." + kept + String(text[fractionEnd...])
            return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        return try? Date(text, strategy: .iso8601)
    }
}
