import Foundation

public struct CodevisorMachine: Identifiable, Sendable, Codable, Equatable {
  public var id: String
  public var name: String
  public var baseURL: URL
  public var kind: String
  public var icon: String?
  public init(id: String, name: String, baseURL: URL, kind: String, icon: String? = nil) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.kind = kind
    self.icon = icon
  }

  public var isLocal: Bool { id == Self.local.id }

  public static func unresolved(id: String) -> CodevisorMachine {
    CodevisorMachine(
      id: id, name: id, baseURL: URL(string: "http://unresolved.invalid")!, kind: "unresolved")
  }

  public var isCloud: Bool { id.hasPrefix(Self.cloudIdPrefix) }

  public var serverConfig: CodevisorServerConfig {
    CodevisorServerConfig(baseURL: baseURL)
  }

  public static let local = CodevisorMachine(
    id: "local",
    name: localDisplayName,
    baseURL: URL(string: "http://127.0.0.1:\(CodevisorServerConfig.localPort)")!,
    kind: "local"
  )

  private static var localDisplayName: String {
    #if os(macOS)
      Host.current().localizedName ?? "Local Codevisor"
    #else
      ProcessInfo.processInfo.hostName
    #endif
  }

  public static let cloudIdPrefix = "cloud:"
  public static let cloudPlaceholderBaseURL = URL(string: "https://cloud-relay.invalid")!

  public static func cloudDeviceId(forMachineId id: String) -> String? {
    guard id.hasPrefix(cloudIdPrefix) else { return nil }
    return String(id.dropFirst(cloudIdPrefix.count))
  }
}
