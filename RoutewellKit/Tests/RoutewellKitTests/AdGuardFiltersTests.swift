import Foundation
import Testing
@testable import RoutewellKit

struct AdGuardFiltersRecordingTests {
    @Test func recorderKeepsListDatesAndPublicListURLs() {
        let value: JSONValue = .object(["filters": .array([
            .object(["url": .string("https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"),
                     "last_updated": .string("2026-01-02T03:04:05+01:00")]),
            .object(["url": .string("https://lists.example.com/private.txt"), "last_updated": .string("yesterday")]),
            .object(["url": .string("http://adguardteam.github.io/list.txt")]),
            .object(["url": .string("https://user@raw.githubusercontent.com/list.txt")]),
        ])])
        let lists = RecordedFixtureRedactor.redact(value)["filters"]?.array ?? []
        #expect(lists[0]["url"]?.string == "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt")
        #expect(lists[0]["last_updated"]?.string == "2026-01-02T03:04:05+01:00")
        #expect(lists[1]["url"]?.string == "[REDACTED TEXT]")
        #expect(lists[1]["last_updated"]?.string == "[REDACTED TEXT]")
        #expect(lists[2]["url"]?.string == "[REDACTED TEXT]")
        #expect(lists[3]["url"]?.string == "[REDACTED TEXT]")
    }
}
