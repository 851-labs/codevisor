import Foundation

public struct ServerPluginAccountGuide: Codable, Equatable, Sendable {
  public struct Link: Codable, Equatable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
      self.title = title
      self.url = url
    }
  }

  public struct Step: Codable, Equatable, Identifiable, Sendable {
    public var title: String
    public var detail: String
    public var link: Link?
    public var fields: [String]

    public var id: String { title }

    public init(title: String, detail: String, link: Link? = nil, fields: [String] = []) {
      self.title = title
      self.detail = detail
      self.link = link
      self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = try container.decode(String.self, forKey: .title)
      detail = try container.decode(String.self, forKey: .detail)
      link = try container.decodeIfPresent(Link.self, forKey: .link)
      fields = try container.decodeIfPresent([String].self, forKey: .fields) ?? []
    }
  }

  public var accountId: String
  public var title: String
  public var summary: String
  public var steps: [Step]

  public init(accountId: String, title: String, summary: String, steps: [Step]) {
    self.accountId = accountId
    self.title = title
    self.summary = summary
    self.steps = steps
  }
}
