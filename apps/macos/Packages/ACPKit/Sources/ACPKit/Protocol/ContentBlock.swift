import Foundation

/// Optional annotations attached to a content block.
public struct Annotations: Sendable, Codable, Equatable {
    public var audience: [Role]?
    public var lastModified: String?
    public var priority: Double?

    public init(audience: [Role]? = nil, lastModified: String? = nil, priority: Double? = nil) {
        self.audience = audience
        self.lastModified = lastModified
        self.priority = priority
    }
}

/// The role of a participant in the conversation.
public enum Role: String, Sendable, Codable, Equatable {
    case user
    case assistant
}

/// Text/blob resource contents embedded directly in a content block.
public enum EmbeddedResource: Sendable, Codable, Equatable {
    case text(uri: String, text: String, mimeType: String?)
    case blob(uri: String, blob: String, mimeType: String?)

    private enum Keys: String, CodingKey {
        case uri, text, blob, mimeType
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let uri = try container.decode(String.self, forKey: .uri)
        let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(uri: uri, text: text, mimeType: mimeType)
        } else {
            let blob = try container.decode(String.self, forKey: .blob)
            self = .blob(uri: uri, blob: blob, mimeType: mimeType)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .text(uri, text, mimeType):
            try container.encode(uri, forKey: .uri)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
        case let .blob(uri, blob, mimeType):
            try container.encode(uri, forKey: .uri)
            try container.encode(blob, forKey: .blob)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
        }
    }
}

/// A block of content exchanged between the client and the agent.
///
/// Discriminated by the `type` field.
public enum ContentBlock: Sendable, Codable, Equatable {
    case text(String, annotations: Annotations? = nil)
    case image(data: String, mimeType: String, uri: String? = nil, annotations: Annotations? = nil)
    case audio(data: String, mimeType: String, annotations: Annotations? = nil)
    case resourceLink(ResourceLink)
    case resource(EmbeddedResource, annotations: Annotations? = nil)

    private enum Keys: String, CodingKey {
        case type, text, data, mimeType, uri, resource, annotations
        case name, description, title, size
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text), annotations: annotations)
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType),
                uri: try container.decodeIfPresent(String.self, forKey: .uri),
                annotations: annotations
            )
        case "audio":
            self = .audio(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType),
                annotations: annotations
            )
        case "resource_link":
            self = .resourceLink(try ResourceLink(from: decoder))
        case "resource":
            self = .resource(
                try container.decode(EmbeddedResource.self, forKey: .resource),
                annotations: annotations
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .text(text, annotations):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case let .image(data, mimeType, uri, annotations):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(uri, forKey: .uri)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case let .audio(data, mimeType, annotations):
            try container.encode("audio", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case let .resourceLink(link):
            try link.encode(to: encoder)
        case let .resource(resource, annotations):
            try container.encode("resource", forKey: .type)
            try container.encode(resource, forKey: .resource)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        }
    }
}

/// A `resource_link` content block referencing an external resource.
public struct ResourceLink: Sendable, Codable, Equatable {
    public var type: String
    public var name: String
    public var uri: String
    public var description: String?
    public var mimeType: String?
    public var title: String?
    public var size: Int64?
    public var annotations: Annotations?

    public init(
        name: String,
        uri: String,
        description: String? = nil,
        mimeType: String? = nil,
        title: String? = nil,
        size: Int64? = nil,
        annotations: Annotations? = nil
    ) {
        self.type = "resource_link"
        self.name = name
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.title = title
        self.size = size
        self.annotations = annotations
    }
}

public extension ContentBlock {
    /// Convenience accessor returning the plain text of a `.text` block.
    var textValue: String? {
        if case .text(let text, _) = self { return text }
        return nil
    }
}
