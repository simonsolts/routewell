import Foundation
import Testing
@testable import RoutewellKit

@Test(arguments: [
    ("192.168.8.1", EndpointScheme.https, "192.168.8.1", 443),
    ("router.lan", .https, "router.lan", 443),
    ("http://192.168.8.1", .http, "192.168.8.1", 80),
    ("https://router.lan:8443", .https, "router.lan", 8443),
    ("[fd00::1]:8443", .https, "fd00::1", 8443),
    ("http://[fd00::1]", .http, "fd00::1", 80),
    ("  router.lan  ", .https, "router.lan", 443),
    ("ROUTER.LAN", .https, "router.lan", 443),
])
func parsesAcceptedInputs(input: String, scheme: EndpointScheme, host: String, port: Int) throws {
    let endpoint = try RouterEndpoint.parse(input)
    #expect(endpoint.scheme == scheme)
    #expect(endpoint.host == host)
    #expect(endpoint.port == port)
}

@Test(arguments: [
    ("", EndpointParseError.empty),
    ("   ", EndpointParseError.empty),
    ("ftp://router.lan", EndpointParseError.invalidScheme),
    ("https://", EndpointParseError.missingHost),
    ("https://user:pw@router.lan", EndpointParseError.userInfoNotAllowed),
    ("https://router.lan/status", EndpointParseError.pathNotAllowed),
    ("https://router.lan?x=1", EndpointParseError.queryNotAllowed),
    ("https://router.lan#frag", EndpointParseError.pathNotAllowed),
    ("https://router.lan:0", EndpointParseError.invalidPort),
    ("https://router.lan:65536", EndpointParseError.invalidPort),
    ("https://router.lan:abc", EndpointParseError.invalidPort),
    ("https://router_lan", EndpointParseError.invalidHost),
    ("https://-router.lan", EndpointParseError.invalidHost),
    ("https://router-.lan", EndpointParseError.invalidHost),
    ("https://router..lan", EndpointParseError.invalidHost),
    ("router .lan", EndpointParseError.invalidHost),
    ("https://" + String(repeating: "a", count: 254), EndpointParseError.invalidHost),
])
func rejectsInvalidInputs(input: String, error: EndpointParseError) {
    #expect(throws: error) { try RouterEndpoint.parse(input) }
}

@Test func displayStringOmitsDefaultPort() throws {
    let https = try RouterEndpoint.parse("192.168.8.1")
    #expect(https.displayString == "https://192.168.8.1")
    #expect(https.isDefaultPort)

    let httpsCustomPort = try RouterEndpoint.parse("https://router.lan:8443")
    #expect(httpsCustomPort.displayString == "https://router.lan:8443")
    #expect(!httpsCustomPort.isDefaultPort)

    let http = try RouterEndpoint.parse("http://192.168.8.1")
    #expect(http.displayString == "http://192.168.8.1")
}

@Test func displayStringBracketsIPv6() throws {
    let endpoint = try RouterEndpoint.parse("[fd00::1]:8443")
    #expect(endpoint.displayString == "https://[fd00::1]:8443")
    #expect(endpoint.url.absoluteString == "https://[fd00::1]:8443/")
}

@Test func urlHasTrailingSlashAndOmitsDefaultPort() throws {
    let endpoint = try RouterEndpoint.parse("router.lan")
    #expect(endpoint.url.absoluteString == "https://router.lan/")
}

@Test func directInitValidatesHostAndPort() {
    #expect(throws: EndpointParseError.invalidPort) { try RouterEndpoint(scheme: .https, host: "router.lan", port: 0) }
    #expect(throws: EndpointParseError.invalidHost) { try RouterEndpoint(scheme: .https, host: "bad host", port: 443) }
}
