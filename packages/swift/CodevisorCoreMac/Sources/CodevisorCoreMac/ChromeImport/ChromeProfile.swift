import Foundation

public struct ChromeProfile: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let directory: URL

  public init(id: String, name: String, directory: URL) {
    self.id = id
    self.name = name
    self.directory = directory
  }

  public var cookies: URL { directory.appending(path: "Cookies") }
  public var picture: URL? {
    let url = directory.appending(path: "Google Profile Picture.png")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
}
