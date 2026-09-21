import Foundation
import Testing
@testable import RoutewellKit

@Test func loginResponseRedactionRemovesCanarySecrets() throws {
    let canary = "ROUTEWELL-CANARY-SECRET"
    let source = try #require("""
    {"token":"\(canary)","sid":"\(canary)","user":"admin"}
    """.data(using: .utf8))

    let result = try PayloadRedactor.redact(source, schema: .loginResponse, aliases: .init())
    let text = try #require(String(data: result, encoding: .utf8))
    #expect(!text.contains(canary))
    #expect(text.contains("[REDACTED]"))
    #expect(text.contains("admin"))
}

@Test func adGuardStatusUsesExplicitStableAliases() throws {
    let source = try #require("""
    {"ip":"192.168.8.20","mac":"AA:BB:CC:DD:EE:FF","name":"Simon's phone","id":"device-42","protection":"enabled"}
    """.data(using: .utf8))
    let aliases = FixtureAliases(ipAddresses: ["192.168.8.20": "198.51.100.9"],
                                 macAddresses: ["AA:BB:CC:DD:EE:FF": "02:00:00:00:00:09"],
                                 names: ["Simon's phone": "Device 9"],
                                 identifiers: ["device-42": "client-9"])

    let result = try PayloadRedactor.redact(source, schema: .adGuardStatus, aliases: aliases)
    let text = try #require(String(data: result, encoding: .utf8))
    #expect(text.contains("198.51.100.9"))
    #expect(text.contains("02:00:00:00:00:09"))
    #expect(text.contains("Device 9"))
    #expect(text.contains("client-9"))
    #expect(!text.contains("192.168.8.20"))
    #expect(!text.contains("Simon's phone"))
    #expect(text.contains("enabled"))
}

@Test func eventLogBoundsEventsAndRedactsBeforeStorageAndExport() async throws {
    let log = SessionEventLog(limit: 2)
    await log.record(.init(level: .info, kind: .session, message: "Connected", fields: ["token": "ROUTEWELL-CANARY-SECRET"]))
    await log.record(.init(level: .info, kind: .refresh, message: "Refresh completed"))
    await log.record(.init(level: .warning, kind: .refresh, message: "token=ROUTEWELL-CANARY-SECRET"))

    let events = await log.events()
    #expect(events.count == 2)
    #expect(events.allSatisfy { !$0.message.contains("ROUTEWELL-CANARY-SECRET") })
    let export = try LogRedactor.export(events)
    let text = try #require(String(data: export, encoding: .utf8))
    #expect(!text.contains("ROUTEWELL-CANARY-SECRET"))
}

@Test func failureCategoriesHaveFixedSafeMessages() {
    #expect(FailureCategory.timeout.message == "The router took too long to respond. Try again.")
    #expect(RefreshFailureCategory.authentication.failureCategory == .authFailed)
}
