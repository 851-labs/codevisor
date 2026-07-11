import Foundation

/// A selectable value for a session configuration option.
public struct SessionConfigSelectOption: Sendable, Codable, Equatable, Identifiable {
    public var value: String
    public var name: String
    public var description: String?

    public var id: String { value }

    public init(value: String, name: String, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }
}

/// A group of selectable values (when an agent groups options under headers).
public struct SessionConfigSelectGroup: Sendable, Codable, Equatable {
    public var group: String
    public var name: String
    public var options: [SessionConfigSelectOption]

    public init(group: String, name: String, options: [SessionConfigSelectOption]) {
        self.group = group
        self.name = name
        self.options = options
    }
}

/// A configurable, single-select session option such as the model, reasoning
/// effort, or approval mode. The `category` is a UX hint and may be absent or
/// unknown.
public struct SessionConfigOption: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var category: String?
    public var currentValue: String
    public var options: [SessionConfigSelectOption]

    private enum Keys: String, CodingKey {
        case id, name, description, category, currentValue, options
    }

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        currentValue: String,
        options: [SessionConfigSelectOption]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.currentValue = currentValue
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        currentValue = try container.decode(String.self, forKey: .currentValue)
        // Options may be a flat list or grouped; flatten either way.
        if let flat = try? container.decode([SessionConfigSelectOption].self, forKey: .options) {
            options = flat
        } else if let grouped = try? container.decode([SessionConfigSelectGroup].self, forKey: .options) {
            options = grouped.flatMap(\.options)
        } else {
            options = []
            if container.contains(.options) {
                let optionId = id
                acpLog.error(
                    "Config option \"\(optionId, privacy: .public)\" options decoded in neither flat nor grouped shape — falling back to none"
                )
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encode(currentValue, forKey: .currentValue)
        try container.encode(options, forKey: .options)
    }

    /// The display name of the currently selected option.
    public var currentName: String {
        options.first { $0.value == currentValue }?.name ?? currentValue
    }
}

public extension SessionConfigOption {
    /// Well-known category identifiers.
    enum Category {
        public static let mode = "mode"
        public static let model = "model"
        public static let modelConfig = "model_config"
        public static let thoughtLevel = "thought_level"
        public static let speed = "speed"
    }
}

/// `session/set_config_option` request params.
public struct SetSessionConfigOptionRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var configId: String
    public var value: String

    public init(sessionId: String, configId: String, value: String) {
        self.sessionId = sessionId
        self.configId = configId
        self.value = value
    }
}

/// `session/set_config_option` response with the updated option set.
public struct SetSessionConfigOptionResponse: Sendable, Codable, Equatable {
    public var configOptions: [SessionConfigOption]

    public init(configOptions: [SessionConfigOption]) {
        self.configOptions = configOptions
    }
}
