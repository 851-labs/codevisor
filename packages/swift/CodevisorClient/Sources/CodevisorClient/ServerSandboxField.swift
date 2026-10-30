import Foundation

public struct ServerSandboxField: Decodable, Equatable, Hashable, Sendable, Identifiable {
  public enum Kind: String, Decodable, Sendable {
    case string, secret, url, number, boolean, choice, machine
  }

  public struct Choice: Decodable, Equatable, Hashable, Sendable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
      self.value = value
      self.label = label
    }
  }

  public var key: String
  public var label: String
  public var type: Kind
  public var required: Bool
  public var defaultValue: SandboxFieldValue?
  public var choices: [Choice]?
  public var placeholder: String?
  public var help: String?
  public var description: String?
  public var min: Double?
  public var max: Double?
  public var steps: [Double]?
  public var fallbackMax: Double?
  public var unit: String?
  public var capability: String?

  public var id: String { key }

  public var awaitsChoices: Bool { type == .choice && choices == nil }

  public static func offered(in error: any Error) -> ServerSandboxField? {
    guard case let CodevisorServerClientError.httpStatus(_, body) = error,
      let reply = try? JSONDecoder().decode(ChoiceNeeded.self, from: Data(body.utf8)),
      reply.code == "sandboxChoiceNeeded"
    else { return nil }
    return reply.details.field
  }

  public init(
    key: String,
    label: String,
    type: Kind,
    required: Bool = false,
    defaultValue: SandboxFieldValue? = nil,
    choices: [Choice]? = nil,
    placeholder: String? = nil,
    help: String? = nil,
    description: String? = nil,
    min: Double? = nil,
    max: Double? = nil,
    steps: [Double]? = nil,
    fallbackMax: Double? = nil,
    unit: String? = nil,
    capability: String? = nil
  ) {
    self.key = key
    self.label = label
    self.type = type
    self.required = required
    self.defaultValue = defaultValue
    self.choices = choices
    self.placeholder = placeholder
    self.help = help
    self.description = description
    self.min = min
    self.max = max
    self.steps = steps
    self.fallbackMax = fallbackMax
    self.unit = unit
    self.capability = capability
  }

  private enum CodingKeys: String, CodingKey {
    case key, label, type, required, choices, placeholder, help, description, min, max, steps, fallbackMax, unit
    case capability
    case defaultValue = "default"
  }
}

private struct ChoiceNeeded: Decodable {
  struct Details: Decodable {
    var field: ServerSandboxField
  }

  var code: String
  var details: Details
}
