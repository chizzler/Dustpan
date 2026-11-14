import Foundation

/// Any JSON value. Field values in the store and the bodies the server exchanges.
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public var isNull: Bool { self == .null }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSON]? { if case .object(let o) = self { o } else { nil } }

    public var int: Int64? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d && abs(d) < 9.2e18: Int64(d)
        default: nil
        }
    }

    /// A number as Double, or nil for anything else (booleans included).
    public var number: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    /// JSON's notion of truthiness for optional fields: set and not null, false, "" or empty.
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .string(let s): !s.isEmpty
        case .array(let a): !a.isEmpty
        case .object(let o): !o.isEmpty
        case .int(let i): i != 0
        case .double(let d): d != 0
        }
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Text

public struct JSONError: Error, CustomStringConvertible {
    public let description: String
}

extension JSON {
    /// Parse JSON text. JSONSerialization is much faster than Codable for the store's many small values.
    public init(parsing data: Data) throws {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONError(description: "invalid JSON: \(error.localizedDescription)")
        }
        self = JSON(any: any)
    }

    /// Most store values are null, a boolean, an integer or a string without escapes: those skip JSONSerialization,
    /// which costs most of a full read of the store.
    public init(parsing text: String) throws {
        switch text {
        case "null": self = .null
        case "true": self = .bool(true)
        case "false": self = .bool(false)
        default:
            if let int = Int64(text) {
                self = .int(int)
            } else if let string = Self.plainString(text) {
                self = .string(string)
            } else {
                try self.init(parsing: Data(text.utf8))
            }
        }
    }

    /// The contents of a quoted string with no escapes, quotes or control characters inside.
    private static func plainString(_ text: String) -> String? {
        let bytes = text.utf8
        guard bytes.count >= 2, bytes.first == UInt8(ascii: "\""), bytes.last == UInt8(ascii: "\"") else { return nil }
        let inner = bytes.dropFirst().dropLast()
        guard !inner.contains(where: { $0 < 0x20 || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }) else {
            return nil
        }
        return String(decoding: inner, as: UTF8.self)
    }

    init(any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.int64Value)
            }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): NSNumber(value: b)
        case .int(let i): NSNumber(value: i)
        case .double(let d): NSNumber(value: d)
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }

    public var data: Data {
        // Every JSON value serializes; only NaN and infinity could fail, and the server never sends them.
        (try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys])) ?? Data("null".utf8)
    }

    public var text: String { String(decoding: data, as: UTF8.self) }
}
