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
  public var min: Double?
  public var max: Double?
  public var capability: String?

  public var id: String { key }

  public init(
    key: String,
    label: String,
    type: Kind,
    required: Bool = false,
    defaultValue: SandboxFieldValue? = nil,
    choices: [Choice]? = nil,
    placeholder: String? = nil,
    help: String? = nil,
    min: Double? = nil,
    max: Double? = nil,
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
    self.min = min
    self.max = max
    self.capability = capability
  }

  private enum CodingKeys: String, CodingKey {
    case key, label, type, required, choices, placeholder, help, min, max, capability
    case defaultValue = "default"
  }
}
