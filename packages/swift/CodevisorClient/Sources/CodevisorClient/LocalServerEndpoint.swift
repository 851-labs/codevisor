import Foundation

public final class LocalServerEndpoint: @unchecked Sendable {
  public static let shared = LocalServerEndpoint(port: CodevisorAppVariant.localServerPort)
  public static let portFileName = "server-port.json"
  public static let mcpOAuthCallbackPath = "/v1/mcps/oauth/callback"

  private let lock = NSLock()
  private var currentPort: Int

  public init(port: Int) {
    currentPort = port
  }

  public var port: Int {
    lock.withLock { currentPort }
  }

  public var baseURL: URL {
    URL(string: "http://127.0.0.1:\(port)")!
  }

  public var mcpOAuthCallbackURL: URL {
    baseURL.appendingPathComponent(Self.mcpOAuthCallbackPath)
  }

  @discardableResult
  public func adoptClaimedPort(fromDataDirectory directory: URL) -> Bool {
    guard let claimed = Self.claimedPort(in: directory) else { return false }
    return update(port: claimed)
  }

  @discardableResult
  public func update(port: Int) -> Bool {
    lock.withLock {
      guard currentPort != port else { return false }
      currentPort = port
      return true
    }
  }

  public static func claimedPort(in directory: URL) -> Int? {
    let file = directory.appendingPathComponent(portFileName)
    guard let data = try? Data(contentsOf: file),
      let record = try? JSONDecoder().decode(ClaimedPort.self, from: data),
      (1...65_535).contains(record.port)
    else { return nil }
    return record.port
  }

  private struct ClaimedPort: Decodable {
    var port: Int
  }
}
