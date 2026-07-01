import Foundation

/// JSON coders configured for ACP wire format.
///
/// `JSONEncoder`/`JSONDecoder` are not safe to share across concurrent tasks,
/// and the connection encodes/decodes from multiple tasks, so fresh instances
/// are vended per access.
public enum ACPJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // ACP messages must not contain embedded newlines (stdio framing),
        // so pretty printing is never used.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder { JSONDecoder() }

    /// Encodes an `Encodable` value into a `JSONValue` for transport through the
    /// dynamic JSON-RPC layer.
    public static func value(from encodable: some Encodable) throws -> JSONValue {
        let data = try encoder.encode(encodable)
        return try decoder.decode(JSONValue.self, from: data)
    }

    /// Decodes a concrete `Decodable` value out of a `JSONValue`.
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try encoder.encode(value)
        return try decoder.decode(type, from: data)
    }
}
