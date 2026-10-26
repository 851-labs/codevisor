import CryptoKit
import Foundation

struct ChromiumBrowserConnection: Equatable {
  let host: String
  let port: Int
  let usesTLS: Bool
  let username: String
  let password: String

  func makeView(machineId: String, address: String) -> CVChromiumView {
    CVChromiumView(
      profile: SHA256.hash(data: Data(machineId.utf8)).map { String(format: "%02x", $0) }.joined(),
      proxyHost: host, proxyPort: port, proxyTLS: usesTLS, username: username, password: password,
      address: address)
  }
}
