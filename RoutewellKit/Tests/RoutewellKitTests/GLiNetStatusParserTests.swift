import Foundation
import Testing
@testable import RoutewellKit

private func loadFixture(_ name: String) -> JSONValue {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/glinet")!
    let data = try! Data(contentsOf: url)
    let envelope = try! JSONDecoder().decode(JSONValue.self, from: data)
    return envelope["result"]!
}

@Suite struct GLiNetStatusParserTests {
    @Test func routerStatusWithNoInputsIsUnknown() {
        let status = GLiNetStatusParser.routerStatus(getStatus: nil, getInfo: nil)
        #expect(status.reachability == .unknown)
        #expect(status.hostname == nil)
        #expect(status.model == nil)
        #expect(status.firmware == nil)
        #expect(status.lanAddress == nil)
        #expect(status.uptimeSeconds == nil)
        #expect(status.loadAverages.isEmpty)
        #expect(status.memoryTotalBytes == nil)
        #expect(status.memoryUsedBytes == nil)
        #expect(status.temperatureCelsius == .unknown)
    }

    @Test func routerStatusFallsBackToTopLevelModel() {
        let getInfo: JSONValue = .object(["model": .string("xe300")])
        let status = GLiNetStatusParser.routerStatus(getStatus: nil, getInfo: getInfo)
        #expect(status.model == "xe300")
        #expect(status.reachability == .connected)
    }

    @Test func routerStatusAcceptsNumericStringLoadAverage() {
        let getStatus: JSONValue = .object([
            "system": .object(["load_average": .array([.string("1.5"), .number(0.9), .string("0.2")])]),
        ])
        let status = GLiNetStatusParser.routerStatus(getStatus: getStatus, getInfo: nil)
        #expect(status.loadAverages == [1.5, 0.9, 0.2])
    }

    @Test func routerStatusMemoryRequiresBothFields() {
        let getStatus: JSONValue = .object(["system": .object(["memory_total": .number(1000)])])
        let status = GLiNetStatusParser.routerStatus(getStatus: getStatus, getInfo: nil)
        #expect(status.memoryTotalBytes == nil)
        #expect(status.memoryUsedBytes == nil)
    }

    @Test func internetStatusOnlineWan() {
        let getStatus: JSONValue = .object(["network": .array([.object(["interface": .string("wan"), "online": .bool(true)])])])
        let internet = GLiNetStatusParser.internetStatus(getStatus: getStatus, cableStatus: nil)
        #expect(internet.reachability == .connected)
        #expect(internet.publicAddress == nil)
    }

    @Test func internetStatusWithoutWanEntryIsUnknown() {
        let getStatus: JSONValue = .object(["network": .array([.object(["interface": .string("wwan"), "online": .bool(true)])])])
        let internet = GLiNetStatusParser.internetStatus(getStatus: getStatus, cableStatus: nil)
        #expect(internet.reachability == .unknown)
    }

    @Test func internetStatusWithNoNetworkArrayIsUnknown() {
        let internet = GLiNetStatusParser.internetStatus(getStatus: nil, cableStatus: nil)
        #expect(internet.reachability == .unknown)
        #expect(internet.publicAddress == nil)
        #expect(internet.dnsServers.isEmpty)
    }

    @Test func clientStatusOfflineClientNotCounted() {
        let clientList: JSONValue = .object(["clients": .array([
            .object(["online": .bool(true)]),
            .object(["online": .bool(false)]),
        ])])
        let clients = GLiNetStatusParser.clientStatus(getStatus: nil, clientList: clientList)
        #expect(clients.activeCount == .value(1))
    }

    @Test func clientStatusFallsBackToGetStatusTotals() {
        let clients = GLiNetStatusParser.clientStatus(getStatus: loadFixture("system-get_status"), clientList: nil)
        #expect(clients.activeCount == .value(1)) // wireless_total 0 + cable_total 1
    }

    @Test func clientStatusFallbackAcceptsNumericStrings() {
        let getStatus: JSONValue = .object(["client": .array([.object(["wireless_total": .string("2"), "cable_total": .string("3")])])])
        let clients = GLiNetStatusParser.clientStatus(getStatus: getStatus, clientList: nil)
        #expect(clients.activeCount == .value(5))
    }

    @Test func clientStatusUnknownWithNoInputs() {
        let clients = GLiNetStatusParser.clientStatus(getStatus: nil, clientList: nil)
        #expect(clients.activeCount == .unknown)
    }
}
