import Foundation

/// A JSON-RPC 2.0 request or response identifier, which may be a string or a number.
public enum JSONRPCID: Sendable, Hashable, Codable, CustomStringConvertible {
    case number(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be a string or number"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// An outbound or inbound JSON-RPC request.
public struct JSONRPCRequest: Sendable, Codable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCID, method: String, params: JSONValue?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC response carrying either a result or an error.
public struct JSONRPCResponse: Sendable, Codable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: JSONRPCID, result: JSONValue?, error: JSONRPCError?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

/// A JSON-RPC notification (a request without an id; no response expected).
public struct JSONRPCNotification: Sendable, Codable, Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// A decoded inbound JSON-RPC message, discriminated by shape.
public enum JSONRPCInbound: Sendable, Equatable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)

    private enum Keys: String, CodingKey {
        case id, method, result, error
    }

    /// Decodes a single JSON-RPC message, distinguishing requests,
    /// notifications, and responses by the presence of `method`/`id`/`result`.
    public init(data: Data) throws {
        let decoder = ACPJSON.decoder
        let probe = try decoder.decode(MessageProbe.self, from: data)
        if probe.method != nil {
            if probe.id != nil {
                self = .request(try decoder.decode(JSONRPCRequest.self, from: data))
            } else {
                self = .notification(try decoder.decode(JSONRPCNotification.self, from: data))
            }
        } else {
            self = .response(try decoder.decode(JSONRPCResponse.self, from: data))
        }
    }

    private struct MessageProbe: Decodable {
        let id: JSONRPCID?
        let method: String?
    }
}
