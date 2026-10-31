import Foundation

public struct ProjectRecommendation: Equatable, Sendable, Identifiable {
  public var folderURL: URL
  public var name: String
  public var sessionCount: Int
  public var lastActivity: Date?

  public var id: String { folderURL.path }

  public init(folderURL: URL, name: String, sessionCount: Int, lastActivity: Date? = nil) {
    self.folderURL = folderURL
    self.name = name
    self.sessionCount = sessionCount
    self.lastActivity = lastActivity
  }
}
