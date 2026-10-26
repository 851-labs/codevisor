import Foundation

public struct BrowserPageError: Equatable, Sendable {
  public let title: String
  public let message: String
  public let systemImage: String
  public let url: String?

  public init(title: String, message: String, systemImage: String = "network.slash", url: String? = nil) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.url = url
  }

  public static func opening(_ message: String) -> BrowserPageError {
    BrowserPageError(title: "Couldn’t Open Page", message: message)
  }

  public static func needsProxyDiagnosis(code: Int) -> Bool {
    [tunnelConnectionFailed, emptyResponse, httpResponseCodeFailure].contains(code)
  }

  public static func load(
    code: Int, description: String, url: String, machine: String, proxyFailure: String? = nil
  ) -> BrowserPageError {
    let host = URL(string: url)?.host() ?? url
    let error = { (title: String, message: String, symbol: String) in
      BrowserPageError(title: title, message: message, systemImage: symbol, url: url)
    }
    switch proxyFailure ?? Self.failure(code: code) {
    case "dns": return error("Can’t Find Server", "\(machine) couldn’t find \(host).", "network.slash")
    case "refused": return error("Can’t Connect to Server", "\(host) refused to connect.", "network.slash")
    case "timeout": return error("Server Not Responding", "\(host) took too long to respond.", "network.slash")
    case "unreachable": return error("Can’t Connect to Server", "\(machine) can’t reach \(host).", "network.slash")
    case "connect", "failed":
      return error("Can’t Connect to Server", "\(machine) couldn’t connect to \(host).", "network.slash")
    case "machine":
      return error("Can’t Reach \(machine)", "Pages load through \(machine). Check that it’s online.", "network.slash")
    case "offline": return error("You’re Offline", "Check your internet connection.", "wifi.slash")
    case "certificate": return error("Connection Not Private", certificateMessage(code: code, host: host), "lock.slash")
    case "insecure":
      return error("Can’t Connect Securely", "\(host) uses an unsupported security protocol.", "lock.slash")
    case "interrupted": return error("Connection Interrupted", "The connection to \(host) was lost.", "network.slash")
    case "redirects": return error("Too Many Redirects", "\(host) redirected too many times.", "network.slash")
    case "port": return error("Can’t Open Page", "Browsers block this port for security.", "network.slash")
    case "server": return error("Page Isn’t Working", "\(host) can’t handle this request right now.", "network.slash")
    default:
      let detail = description.isEmpty ? "Error \(code)" : description
      return error("Can’t Open Page", "\(machine) couldn’t load \(host). \(detail)", "network.slash")
    }
  }

  private static let tunnelConnectionFailed = -111
  private static let emptyResponse = -324
  private static let httpResponseCodeFailure = -379

  private static func failure(code: Int) -> String? {
    switch code {
    case -105, -137: "dns"
    case -102: "refused"
    case -7, -118: "timeout"
    case -109: "unreachable"
    case -130: "machine"
    case -106: "offline"
    case -299 ... -200: "certificate"
    case -107, -113: "insecure"
    case -21, -100, -101: "interrupted"
    case -310: "redirects"
    case -312: "port"
    case tunnelConnectionFailed: "connect"
    case httpResponseCodeFailure, emptyResponse: "server"
    default: nil
    }
  }

  private static func certificateMessage(code: Int, host: String) -> String {
    switch code {
    case -200: "This certificate isn’t valid for \(host)."
    case -201: "The certificate for \(host) has expired or isn’t valid yet."
    case -202: "The certificate for \(host) isn’t from a trusted authority."
    case -206: "The certificate for \(host) has been revoked."
    default: "The certificate for \(host) isn’t valid."
    }
  }
}
