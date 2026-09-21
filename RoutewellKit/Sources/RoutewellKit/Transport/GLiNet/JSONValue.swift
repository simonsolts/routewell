import Foundation

/// A minimal enum-backed JSON tree used to decode GL.iNet RPC results without
/// committing to concrete Swift types for a router API whose shape is "assumed".
///
/// NOTE: kept minimal on purpose — this file is one of two duplicated between
/// chunk 09 task 5 and task 6 branches. The coordinator keeps one copy at merge.
public indirect enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var double: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var int: Int? {
        switch self {
        case .number(let value):
            guard value == value.rounded(.towardZero), value.isFinite else { return nil }
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    public var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var object: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
