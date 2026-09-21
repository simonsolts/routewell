import Foundation
import Testing
@testable import RoutewellKit

@Test func jsonValueDecodesEveryCase() throws {
    let source = try #require("""
    {"n":null,"b":true,"num":1.5,"s":"text","a":[1,2,3],"o":{"x":1}}
    """.data(using: .utf8))
    let value = try JSONDecoder().decode(JSONValue.self, from: source)
    #expect(value["n"] == .null)
    #expect(value["b"]?.bool == true)
    #expect(value["num"]?.double == 1.5)
    #expect(value["s"]?.string == "text")
    #expect(value["a"]?.array?.count == 3)
    #expect(value["o"]?["x"]?.int == 1)
}

@Test func intAcceptsIntegralNumberAndNumericString() {
    #expect(JSONValue.number(1).int == 1)
    #expect(JSONValue.string("1").int == 1)
    #expect(JSONValue.number(1.5).int == nil)
    #expect(JSONValue.string("not-a-number").int == nil)
}

@Test func boolOnlyAcceptsBoolCase() {
    #expect(JSONValue.bool(true).bool == true)
    #expect(JSONValue.string("true").bool == nil)
    #expect(JSONValue.number(1).bool == nil)
}

@Test func subscriptsReturnNilForWrongShape() {
    let value = JSONValue.string("text")
    #expect(value["key"] == nil)
    #expect(value[0] == nil)
}

@Test func arraySubscriptOutOfBoundsReturnsNil() {
    let value = JSONValue.array([.number(1), .number(2)])
    #expect(value[1]?.int == 2)
    #expect(value[5] == nil)
    #expect(value[-1] == nil)
}

@Test func encodeThenDecodeRoundTrips() throws {
    let value = JSONValue.object([
        "a": .array([.null, .bool(false), .number(2), .string("x")]),
        "o": .object(["k": .string("v")]),
    ])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
}

@Test func objectAndArrayAccessorsReturnUnderlyingCollections() {
    let object = JSONValue.object(["a": .number(1)])
    #expect(object.object?["a"]?.int == 1)
    #expect(object.array == nil)

    let array = JSONValue.array([.number(1)])
    #expect(array.array?.count == 1)
    #expect(array.object == nil)
}
