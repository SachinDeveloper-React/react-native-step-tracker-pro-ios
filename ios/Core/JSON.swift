import Foundation

/// A JSON value with ordered object keys.
///
/// The signed snapshot is built from this, so the bytes that are signed are
/// exactly the bytes this file writes: integers as integers, no NaN or
/// infinity, no undefined values - the same rules Android's org.json
/// follows, so a server parses either platform's payload with one parser.
indirect enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    static func == (lhs: JSON, rhs: JSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b || (a.isNaN && b.isNaN)
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    // ---- building ------------------------------------------------------------

    static func int(_ value: Int) -> JSON { .int(Int64(value)) }

    static func optional(_ value: String?) -> JSON { value.map { .string($0) } ?? .null }

    static func optional(_ value: Int64?) -> JSON { value.map { .int($0) } ?? .null }

    static func optional(_ value: Int?) -> JSON { value.map { .int(Int64($0)) } ?? .null }

    static func strings(_ values: [String]) -> JSON { .array(values.map { .string($0) }) }

    static func ints(_ values: [Int]) -> JSON { .array(values.map { .int(Int64($0)) }) }

    // ---- reading -------------------------------------------------------------

    subscript(key: String) -> JSON? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }

    var keys: [String] {
        guard case let .object(pairs) = self else { return [] }
        return pairs.map(\.0)
    }

    var int64Value: Int64? {
        switch self {
        case let .int(v): return v
        case let .double(v) where v.isFinite && v == v.rounded(.towardZero) && abs(v) < 9.2e18: return Int64(v)
        default: return nil
        }
    }

    var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }

    var doubleValue: Double? {
        switch self {
        case let .int(v): return Double(v)
        case let .double(v): return v
        default: return nil
        }
    }

    var stringValue: String? {
        if case let .string(v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(v) = self { return v }
        return nil
    }

    var arrayValue: [JSON]? {
        if case let .array(v) = self { return v }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The same object with [key] set - replaced in place, or appended.
    func setting(_ key: String, _ value: JSON) -> JSON {
        guard case var .object(pairs) = self else { return self }
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[index].1 = value
        } else {
            pairs.append((key, value))
        }
        return .object(pairs)
    }

    // ---- writing -------------------------------------------------------------

    /// Compact UTF-8 JSON text.
    func serialized() -> String {
        var out = ""
        out.reserveCapacity(256)
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(v): out += v ? "true" : "false"
        case let .int(v): out += String(v)
        case let .double(v): out += JSON.number(v)
        case let .string(v): JSON.quote(v, into: &out)
        case let .array(values):
            out += "["
            for (i, value) in values.enumerated() {
                if i > 0 { out += "," }
                value.write(into: &out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                JSON.quote(pair.0, into: &out)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }

    /// A double as JSON: null when not finite, an integer when whole.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(.towardZero) && abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        // Swift prints the shortest text that reads back as the same
        // double: "0.1", "1e-05", "1.5e+20" - all valid JSON.
        return "\(value)"
    }

    static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // ---- Foundation ----------------------------------------------------------

    /// Foundation objects for the React Native bridge and JSONSerialization.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(v): return NSNumber(value: v)
        case let .int(v): return NSNumber(value: v)
        case let .double(v): return v.isFinite ? NSNumber(value: v) : NSNull()
        case let .string(v): return v
        case let .array(values): return values.map(\.foundation)
        case let .object(pairs):
            var dict = [String: Any](minimumCapacity: pairs.count)
            for (key, value) in pairs { dict[key] = value.foundation }
            return dict
        }
    }

    /// From whatever Foundation handed over - the bridge's arguments, or
    /// JSONSerialization's output. Unknown types become null.
    init(foundation value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let v as String: self = .string(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if CFNumberIsFloatType(v) {
                let d = v.doubleValue
                if d.isFinite && d == d.rounded(.towardZero) && abs(d) < 9_007_199_254_740_992 {
                    self = .int(Int64(d))
                } else {
                    self = .double(d)
                }
            } else {
                self = .int(v.int64Value)
            }
        case let v as [Any]: self = .array(v.map { JSON(foundation: $0) })
        case let v as [String: Any]:
            self = .object(v.keys.sorted().map { ($0, JSON(foundation: v[$0])) })
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(Int64(v))
        case let v as Int64: self = .int(v)
        case let v as Double: self = .double(v)
        default: self = .null
        }
    }

    static func parse(_ data: Data) -> JSON? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSON(foundation: object)
    }

    static func parse(_ text: String) -> JSON? { parse(Data(text.utf8)) }
}
