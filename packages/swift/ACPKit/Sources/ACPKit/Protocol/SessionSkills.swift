import Foundation

/// Where a composer skill comes from: shipped with the harness (`builtin`),
/// the workspace's or the user's skill folders (`project`, `user`), a harness
/// plugin (`plugin`), or Codevisor's own skill store (`codevisor`).
public enum SessionSkillSource: String, Sendable, Codable, Equatable {
  case builtin
  case project
  case user
  case plugin
  case codevisor
}

/// One skill the user can invoke from the composer. Harness commands that
/// are not skills (`/compact`, `/model`, …) are never listed.
public struct SessionSkill: Sendable, Codable, Equatable, Identifiable {
  public var name: String
  public var description: String?
  /// The exact text that invokes the skill in this harness's prompt:
  /// "/review" (Claude, OpenCode, Cursor, Grok), "$review" (Codex), or
  /// "/skill:review" (Pi).
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
    // Lenient: a source a newer server adds decodes as nil instead of
    // dropping the whole skill list.
    source = (try? container.decodeIfPresent(String.self, forKey: .source))
      .flatMap(SessionSkillSource.init(rawValue:))
  }
}

/// The skills a harness session can invoke, as one replaceable snapshot. It
/// rides on harness capabilities (for chats that have not started their
/// harness yet) and as the `available_skills_update` session update.
public struct SessionSkills: Sendable, Codable, Equatable {
  public var skills: [SessionSkill]
  /// The prefix that invokes a skill the harness does not know natively
  /// (Codevisor store skills): "$" for Codex, "/" elsewhere.
  public var invocationPrefix: String

  public init(skills: [SessionSkill], invocationPrefix: String = "/") {
    self.skills = skills
    self.invocationPrefix = invocationPrefix
  }
}
