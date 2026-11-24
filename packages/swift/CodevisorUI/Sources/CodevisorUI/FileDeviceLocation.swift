import Foundation

public struct FileDeviceLocation: Equatable, Sendable {
  public let url: URL
  public let name: String

  private static let origin = "https://device.codevisor.invalid/"

  public init(url: URL, name: String) {
    self.url = url
    self.name = name
  }

  public init?(_ target: String) {
    guard target.hasPrefix(Self.origin), let components = URLComponents(string: target),
      let name = components.queryItems?.first(where: { $0.name == "name" })?.value, !name.isEmpty,
      components.path.count > 1
    else { return nil }

    self.init(url: URL(fileURLWithPath: components.path), name: name)
  }

  public var target: String {
    var components = URLComponents(string: Self.origin)!
    components.path = url.path
    components.queryItems = [URLQueryItem(name: "name", value: name)]
    return components.string!
  }

  @concurrent
  func data() async throws -> Data {
    try Data(contentsOf: url, options: .mappedIfSafe)
  }
}
