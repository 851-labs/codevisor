import CodevisorClient
import ScreenSharing
import ScreenSharingWebRTC
import CryptoKit
import Foundation

/// TURN REST credentials expire five minutes after issuance. Only the host
/// process has the shared secret; the viewer receives an HMAC-derived password.
struct ScreenSharingHostConnectivity {
  let environment: [String: String]
  var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

  func make(viewerId: UUID) throws -> ServerScreenSharingConnectivity {
    func urls(_ key: String) -> [String] {
      (environment[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    let stun = urls("CODEVISOR_SCREEN_SHARING_STUN_URLS")
    let turn = urls("CODEVISOR_SCREEN_SHARING_TURN_URLS")
    let expires = Int(now()) + 300
    var servers: [ServerScreenSharingConnectivity.Server] = []
    guard stun.allSatisfy({ $0.hasPrefix("stun:") || $0.hasPrefix("stuns:") }),
      turn.allSatisfy({ $0.hasPrefix("turn:") || $0.hasPrefix("turns:") })
    else {
      throw ScreenSharingError.invalid("Screen Sharing connectivity URLs use the wrong protocol.")
    }
    if !stun.isEmpty { servers.append(.init(urls: stun)) }
    if !turn.isEmpty {
      guard let secret = environment["CODEVISOR_SCREEN_SHARING_TURN_SECRET"], !secret.isEmpty, secret.utf8.count <= 1024
      else { throw ScreenSharingError.unavailable("Configure the Screen Sharing TURN secret on the host Mac.") }
      let username = "\(expires):codevisor:\(viewerId.uuidString.lowercased())"
      let password = Data(
        HMAC<Insecure.SHA1>.authenticationCode(
          for: Data(username.utf8), using: SymmetricKey(data: Data(secret.utf8)))
      ).base64EncodedString()
      servers.append(.init(urls: turn, username: username, credential: password))
    }
    let policy = environment["CODEVISOR_SCREEN_SHARING_RELAY_ONLY"] ?? "0"
    guard ["0", "1"].contains(policy) else { throw ScreenSharingError.invalid("Invalid Screen Sharing relay policy.") }
    let result = ServerScreenSharingConnectivity(servers: servers, relayOnly: policy == "1", expiresAt: expires)
    _ = try result.native()
    return result
  }
}

extension ServerScreenSharingConnectivity {
  func native() throws -> ScreenSharingICEConfiguration {
    try .init(
      servers: servers.map { try .init(urls: $0.urls, username: $0.username, credential: $0.credential) },
      relayOnly: relayOnly)
  }
}
