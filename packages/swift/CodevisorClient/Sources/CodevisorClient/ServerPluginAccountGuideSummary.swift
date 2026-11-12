import Foundation

public struct ServerPluginAccountGuideSummary: Codable, Equatable, Sendable {
  public var title: String
  public var summary: String
  public var steps: [ServerPluginAccountGuide.Step]

  public init(title: String, summary: String, steps: [ServerPluginAccountGuide.Step] = []) {
    self.title = title
    self.summary = summary
    self.steps = steps
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decode(String.self, forKey: .title)
    summary = try container.decode(String.self, forKey: .summary)
    steps = try container.decodeIfPresent([ServerPluginAccountGuide.Step].self, forKey: .steps) ?? []
  }
}
