import Foundation

/// The kind of a permission option presented to the user.
public enum PermissionOptionKind: String, Sendable, Codable, Equatable, CaseIterable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"
}

/// A single permission choice offered to the user.
public struct PermissionOption: Sendable, Codable, Equatable, Identifiable {
    public var optionId: String
    public var name: String
    public var kind: PermissionOptionKind

    public var id: String { optionId }

    public init(optionId: String, name: String, kind: PermissionOptionKind) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}

/// `session/request_permission` request params.
public struct RequestPermissionRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var toolCall: ToolCallUpdate
    public var options: [PermissionOption]

    public init(sessionId: String, toolCall: ToolCallUpdate, options: [PermissionOption]) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
    }
}

/// The user's response to a permission request. Discriminated by `outcome`.
public enum RequestPermissionOutcome: Sendable, Codable, Equatable {
    case cancelled
    case selected(optionId: String)

    private enum Keys: String, CodingKey {
        case outcome, optionId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        switch outcome {
        case "cancelled":
            self = .cancelled
        case "selected":
            self = .selected(optionId: try container.decode(String.self, forKey: .optionId))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Unknown permission outcome: \(outcome)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .cancelled:
            try container.encode("cancelled", forKey: .outcome)
        case let .selected(optionId):
            try container.encode("selected", forKey: .outcome)
            try container.encode(optionId, forKey: .optionId)
        }
    }
}

/// `session/request_permission` response.
public struct RequestPermissionResponse: Sendable, Codable, Equatable {
    public var outcome: RequestPermissionOutcome

    public init(outcome: RequestPermissionOutcome) {
        self.outcome = outcome
    }
}
