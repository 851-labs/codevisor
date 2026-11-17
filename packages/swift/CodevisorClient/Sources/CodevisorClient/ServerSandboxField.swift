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

    func exceeds(_ maximum: Double) -> Bool {
      Double(value).map { $0 > maximum } ?? false
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
  public var replacedBy: String?

  public var id: String { key }

  public var note: String? { description ?? help }

  public var emptyPrompt: String {
    if !required, defaultValue == nil { return "Optional" }
    return placeholder ?? defaultValue?.text ?? "Required"
  }

  public var awaitsChoices: Bool { type == .choice && choices == nil }

  public static func offered(in error: any Error) -> ServerSandboxField? {
    guard case let CodevisorServerClientError.httpStatus(_, body) = error,
      let reply = try? JSONDecoder().decode(ChoiceNeeded.self, from: Data(body.utf8)),
      reply.code == "sandboxChoiceNeeded"
    else { return nil }
    return reply.details.field
  }

  public static func refusedKey(in error: any Error) -> String? {
    guard case let CodevisorServerClientError.httpStatus(_, body) = error,
      let reply = try? JSONDecoder().decode(FieldRefused.self, from: Data(body.utf8)),
      reply.code == "sandboxFieldInvalid"
    else { return nil }
    return reply.details.key
  }

  public func limited(to maximum: Double?, keeping saved: String?) -> ServerSandboxField {
    guard let maximum, let choices else { return self }

    var limited = self
    limited.choices = choices.filter { $0.value == saved || !$0.exceeds(maximum) }
    return limited
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
    capability: String? = nil,
    replacedBy: String? = nil
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
    self.replacedBy = replacedBy
  }

  private enum CodingKeys: String, CodingKey {
    case key, label, type, required, choices, placeholder, help, description, min, max, steps, fallbackMax, unit
    case capability, replacedBy
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

private struct FieldRefused: Decodable {
  struct Details: Decodable {
    var key: String
  }

  var code: String
  var details: Details
}
