import Foundation

public enum SessionSkillSource: String, Sendable, Codable, Equatable {
  case builtin
  case project
  case user
  case plugin
  case codevisor
}

public struct SessionSkill: Sendable, Codable, Equatable, Identifiable {
  public var name: String
  public var description: String?
  public var invocation: String
  public var source: SessionSkillSource?

  public var id: String { invocation }

  private enum CodingKeys: String, CodingKey {
    case name, description, invocation, source
  }

  public init(
    name: String,
    description: String? = nil,
    invocation: String,
    source: SessionSkillSource? = nil
  ) {
    self.name = name
    self.description = description
    self.invocation = invocation
    self.source = source
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    invocation = try container.decode(String.self, forKey: .invocation)
    source = (try? container.decodeIfPresent(String.self, forKey: .source))
      .flatMap(SessionSkillSource.init(rawValue:))
  }
}

public struct SessionSkills: Sendable, Codable, Equatable {
  public static let compactCommand = "compact"

  public var skills: [SessionSkill]
  public var invocationPrefix: String
  public var commands: [String]?

  public init(skills: [SessionSkill], invocationPrefix: String = "/", commands: [String]? = nil) {
    self.skills = skills
    self.invocationPrefix = invocationPrefix
    self.commands = commands
  }

  public var acceptsCompact: Bool { commands?.contains(Self.compactCommand) == true }
}
