import Foundation

public struct RigMachine: Sendable, Equatable, Identifiable, Hashable {
  public enum Connection: Sendable, Equatable, Hashable {
    case server(URL, sshTarget: String)
    case vnc(host: String, port: UInt16, password: RigVNCPassword)
  }

  public let id: String
  public let name: String
  public let detail: String
  public let connection: Connection
  public let systemImage: String

  public init(id: String, name: String, detail: String, connection: Connection, systemImage: String) {
    self.id = id
    self.name = name
    self.detail = detail
    self.connection = connection
    self.systemImage = systemImage
  }

  public static func tokenCommandArguments(sshTarget: String) -> [String] {
    ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", sshTarget, #"PATH="$PATH:$HOME/.local/bin" codevisor token"#]
  }

  public static func vncDisplayId(port: UInt16) -> String { "vnc:\(port)" }

  public static func loopback(port: UInt16, password: String?) -> RigMachine {
    RigMachine(
      id: "loopback", name: "Loopback server", detail: "The rig's test VNC server on 127.0.0.1:\(port)",
      connection: .vnc(host: "127.0.0.1", port: port, password: password.map(RigVNCPassword.fixed) ?? .none),
      systemImage: "arrow.triangle.2.circlepath")
  }

  public static let catalog: [RigMachine] = [
    RigMachine(
      id: "contabo-vps",
      name: "Contabo VPS",
      detail: "Xfce over the server's VNC socket, via Tailscale",
      connection: .server(URL(string: "http://contabo-vps.tail6fc9a.ts.net:49361")!, sshTarget: "root@164.68.121.169"),
      systemImage: "server.rack"),
    RigMachine(
      id: "tuftlord-mac",
      name: "tuftlord · VNC",
      detail: "macOS Screen Sharing on tuftlords-macbook-pro, via Tailscale",
      connection: .vnc(host: "tuftlords-macbook-pro.tail6fc9a.ts.net", port: 5900, password: .keychain),
      systemImage: "laptopcomputer"),
    RigMachine(
      id: "tuftlord-native",
      name: "tuftlord · High Performance",
      detail: "Codevisor native screen sharing on tuftlords-macbook-pro, via Tailscale",
      connection: .server(
        URL(string: "http://tuftlords-macbook-pro.tail6fc9a.ts.net:49361")!,
        sshTarget: "tuftlord@tuftlords-macbook-pro.tail6fc9a.ts.net"),
      systemImage: "laptopcomputer"),
  ]
}
