import Foundation

public struct CodevisorMachine: Identifiable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var address: ServerAddress
  public var kind: String
  public var icon: MachineIcon

  public var baseURL: URL {
    get { address.url }
    set { address = .fixed(newValue) }
  }

  public init(id: String, name: String, baseURL: URL, kind: String, icon: String? = nil) {
    self.init(id: id, name: name, address: .fixed(baseURL), kind: kind, icon: icon)
  }

  public init(id: String, name: String, address: ServerAddress, kind: String, icon: String? = nil) {
    self.id = id
    self.name = name
    self.address = address
    self.kind = kind
    self.icon = MachineIcon(resolving: icon)
  }

  public var isLocal: Bool { id == Self.local.id }

  public static func unresolved(id: String) -> CodevisorMachine {
    CodevisorMachine(
      id: id, name: id, baseURL: URL(string: "http://unresolved.invalid")!, kind: "unresolved")
  }

  public var isCloud: Bool { id.hasPrefix(Self.cloudIdPrefix) }

  public var serverConfig: CodevisorServerConfig {
    CodevisorServerConfig(address: address)
  }

  public static let local = CodevisorMachine(
    id: "local",
    name: localDisplayName,
    address: .localServer(.shared),
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
