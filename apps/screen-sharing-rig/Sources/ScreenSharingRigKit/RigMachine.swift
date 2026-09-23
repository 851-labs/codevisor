import Foundation

/// A machine the rig window lists under Machines, viewed with the product's
/// own Screen Sharing feature. Either a Codevisor server, reached the way the
/// product's pane reaches it, or a VNC server reached directly (the rig's
/// loopback server while it runs). A server's bearer token is not stored
/// here; the rig asks the machine for it once over SSH (`codevisor token`)
/// and keeps it in the Keychain. Nor is a VNC machine's password: the rig asks
/// the user once (`RigVNCPassword.keychain`).
public struct RigMachine: Sendable, Equatable, Identifiable, Hashable {
  public enum Connection: Sendable, Equatable, Hashable {
    /// A Codevisor server; `sshTarget` (`user@host`) can run `codevisor token` non-interactively.
    case server(URL, sshTarget: String)
    /// A VNC server by address, with no Codevisor server in front of it.
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

  /// `/usr/bin/ssh` arguments that print a server machine's connection token
  /// and never prompt: a GUI app has no terminal to answer one.
  public static func tokenCommandArguments(sshTarget: String) -> [String] {
    ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", sshTarget, "codevisor", "token"]
  }

  /// The display id a direct VNC machine reports, in the server's `vnc:<port>` form.
  public static func vncDisplayId(port: UInt16) -> String { "vnc:\(port)" }

  /// The rig's in-process loopback VNC server while it serves on `port`.
  public static func loopback(port: UInt16, password: String?) -> RigMachine {
    RigMachine(
      id: "loopback", name: "Loopback server", detail: "The rig's test VNC server on 127.0.0.1:\(port)",
      connection: .vnc(host: "127.0.0.1", port: port, password: password.map(RigVNCPassword.fixed) ?? .none),
      systemImage: "arrow.triangle.2.circlepath")
  }

  /// The machines every rig window starts with.
  public static let catalog: [RigMachine] = [
    RigMachine(
      id: "contabo-vps",
      name: "Contabo VPS",
      detail: "Xfce over the server's VNC socket, via Tailscale",
      connection: .server(URL(string: "http://contabo-vps.tail6fc9a.ts.net:49361")!, sshTarget: "root@164.68.121.169"),
      systemImage: "server.rack"),
    // Apple's own Screen Sharing server, with "VNC viewers may control screen with password" on.
    RigMachine(
      id: "tuftlord-mac",
      name: "tuftlord",
      detail: "macOS Screen Sharing (VNC password) on tuftlords-macbook-pro.local",
      connection: .vnc(host: "tuftlords-macbook-pro.local", port: 5900, password: .keychain),
      systemImage: "laptopcomputer"),
  ]
}
