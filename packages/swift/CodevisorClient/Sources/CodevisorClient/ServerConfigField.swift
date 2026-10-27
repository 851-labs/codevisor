import Foundation

public struct ServerConfigField: Codable, Equatable, Identifiable, Sendable {
  public struct Choice: Codable, Equatable, Identifiable, Sendable {
    public var value: String
    public var label: String

    public var id: String { value }

    public init(value: String, label: String) {
      self.value = value
      self.label = label
    }
  }

  public struct Condition: Codable, Equatable, Sendable {
    public var key: String
    public var op: String
    public var value: ServerConfigFieldValue

    public init(key: String, op: String, value: ServerConfigFieldValue) {
      self.key = key
      self.op = op
      self.value = value
    }

    public func holds(in values: [String: ServerConfigFieldValue]) -> Bool {
      let matches = values[key] == value
      return op == "neq" ? !matches : matches
    }
  }

  public var key: String
  public var label: String
  public var type: ServerConfigFieldType
  public var required: Bool
  public var `default`: ServerConfigFieldValue?
  public var choices: [Choice]?
  public var placeholder: String?
  public var help: String?
  public var min: Double?
  public var max: Double?
  public var generated: Bool?
  public var when: Condition?

  public var id: String { key }

  public var isSecret: Bool { type == .secret }

  public var isGenerated: Bool { generated == true }

  public init(
    key: String,
    label: String,
    type: ServerConfigFieldType,
    required: Bool = false,
    default: ServerConfigFieldValue? = nil,
    choices: [Choice]? = nil,
    placeholder: String? = nil,
    help: String? = nil,
    when: Condition? = nil
  ) {
    self.key = key
    self.label = label
    self.type = type
    self.required = required
    self.default = `default`
    self.choices = choices
    self.placeholder = placeholder
    self.help = help
    self.when = when
  }

  public func isVisible(with values: [String: ServerConfigFieldValue]) -> Bool {
    when?.holds(in: values) ?? true
  }
}
