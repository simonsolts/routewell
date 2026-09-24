import Foundation

/// `GET control/querylog`: `{"oldest": ISO-8601, "data": [...]}` with
/// `time`, `client`, `question.name`, and `reason` per entry `[verified live]`
/// on 4.9.1. Entries that are not objects are skipped; missing fields stay
/// unknown.
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
        let entries = list.compactMap { item -> QueryLogEntry? in
            guard item.object != nil else { return nil }
            return QueryLogEntry(
                time: item["time"]?.string.flatMap(timestamp),
                client: ClientText.meaningful(item["client"]),
                domain: ClientText.meaningful(item["question"]?["name"]),
                reason: ClientText.meaningful(item["reason"])
            )
        }
        return QueryLogPage(entries: entries, oldest: json["oldest"]?.string.flatMap(timestamp), limit: limit)
    }

    /// AdGuard Home writes nanosecond fractions (`…:40.610777106Z`). The
    /// fraction is cut to milliseconds before parsing.
    static func timestamp(_ raw: String) -> Date? {
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
