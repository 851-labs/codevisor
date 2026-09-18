import Foundation
@preconcurrency import WebRTC
import ScreenSharing

public struct ScreenSharingICEServer: Sendable {
  public let urls: [String]
  public let username: String
  public let credential: String
  public init(urls: [String], username: String = "", credential: String = "") throws {
    guard (1...8).contains(urls.count), username.utf8.count <= 512, credential.utf8.count <= 1024 else {
      throw ScreenSharingError.invalid("Invalid Screen Sharing connectivity configuration.")
    }
    for url in urls {
      guard Self.validURL(url),
        !url.hasPrefix("turn") || (!username.isEmpty && !credential.isEmpty)
      else { throw ScreenSharingError.invalid("Invalid Screen Sharing STUN or TURN server.") }
    }
    self.urls = urls; self.username = username; self.credential = credential
  }
  public static func validURL(_ value: String) -> Bool {
    guard value.utf8.count <= 2048, let colon = value.firstIndex(of: ":") else { return false }
    let scheme = String(value[..<colon])
    guard ["stun", "stuns", "turn", "turns"].contains(scheme),
      let url = URLComponents(string: "https://" + value[value.index(after: colon)...]),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
      url.path.isEmpty, url.fragment == nil,
      url.port.map({ (1...65535).contains($0) }) ?? true
    else { return false }
    if let query = url.query {
      guard scheme.hasPrefix("turn"), ["transport=udp", "transport=tcp"].contains(query) else { return false }
      if scheme == "turns", query != "transport=tcp" { return false }
    }
    return !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
  }
  var native: RTCIceServer { RTCIceServer(urlStrings: urls, username: username, credential: credential) }
}

public struct ScreenSharingICEConfiguration: Sendable {
  public let servers: [ScreenSharingICEServer]
  public let relayOnly: Bool
  public init(servers: [ScreenSharingICEServer] = [], relayOnly: Bool = false) throws {
    guard servers.count <= 8,
      !relayOnly || servers.contains(where: { $0.urls.contains(where: { $0.hasPrefix("turn") }) })
    else { throw ScreenSharingError.invalid("Relay-only Screen Sharing requires a TURN server.") }
    self.servers = servers; self.relayOnly = relayOnly
  }
}
