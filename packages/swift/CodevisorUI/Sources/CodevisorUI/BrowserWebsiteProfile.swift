import CodevisorClient
import CryptoKit
import Foundation
import Network
import WebKit

/// A machine is a browser profile: identical localhost origins on different
/// machines must never share credentials, localStorage, or service workers.
@MainActor
final class BrowserWebsiteProfile {
  private static var profiles: [String: BrowserWebsiteProfile] = [:]
  let store: WKWebsiteDataStore
  var cookieSync: BrowserCookieSync?
  private var panes: Set<UUID> = []
  private var endpoint: URL?
  private var credential: ServerBrowserProxySession?

  static func retain(machineId: String, paneId: UUID) {
    guard let profile = profiles[machineId] else { return }
    profile.panes.insert(paneId); profile.cookieSync?.start()
  }
  static func release(machineId: String, paneId: UUID) {
    guard let profile = profiles[machineId] else { return }
    profile.panes.remove(paneId)
    if profile.panes.isEmpty { profile.cookieSync?.stop() }
  }
  static func sync(machineId: String) -> BrowserCookieSync? { profiles[machineId]?.cookieSync }

  private init(machineId: String) {
    let bytes = Array(SHA256.hash(data: Data("browser:\(machineId)".utf8)).prefix(16))
    store = WKWebsiteDataStore(forIdentifier: NSUUID(uuidBytes: bytes) as UUID)
  }

  static func configuredStore(
    machineId: String, endpoint: URL, credential: ServerBrowserProxySession,
    client: (any CodevisorServerClienting)? = nil
  ) throws -> WKWebsiteDataStore {
    guard let host = endpoint.host,
      let rawPort = UInt16(exactly: endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)),
      let port = NWEndpoint.Port(rawValue: rawPort),
      ["http", "https"].contains(endpoint.scheme)
    else { throw URLError(.badURL) }
    let profile = profiles[machineId] ?? BrowserWebsiteProfile(machineId: machineId)
    profiles[machineId] = profile
    if profile.endpoint != endpoint || profile.credential != credential {
      var proxy = ProxyConfiguration(
        httpCONNECTProxy: .hostPort(host: .init(host), port: port),
        tlsOptions: endpoint.scheme == "https" ? NWProtocolTLS.Options() : nil
      )
      proxy.allowFailover = false
      proxy.applyCredential(username: credential.username, password: credential.password)
      profile.store.proxyConfigurations = [proxy]
      profile.endpoint = endpoint
      profile.credential = credential
    }
    if profile.cookieSync == nil, let client {
      let cookies = profile.store.httpCookieStore
      profile.cookieSync = BrowserCookieSync(
        client: client,
        read: {
          let stored = await cookies.allCookies()
          for old in stored where old.domain == "codevisor.localhost" || old.domain.hasSuffix(".codevisor.localhost") {
            if let migrated = BrowserCookie(webKit: old)?.webKitCookie {
              await cookies.setCookie(migrated)
              await cookies.deleteCookie(old)
            }
          }
          return stored.compactMap(BrowserCookie.init(webKit:))
        },
        apply: { cookie, previous in
          if let previous {
            for existing in await cookies.allCookies() where BrowserCookie(webKit: existing)?.key == previous.key {
              await cookies.deleteCookie(existing)
            }
          }
          if let cookie, let native = cookie.webKitCookie { await cookies.setCookie(native) }
        })
    }
    return profile.store
  }
}

private extension WKHTTPCookieStore {
  func allCookies() async -> [HTTPCookie] {
    await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } }
  }
}

private extension BrowserCookie {
  init?(webKit cookie: HTTPCookie) {
    guard cookie.properties?[HTTPCookiePropertyKey("Partitioned")] == nil else { return nil }
    let dotted = cookie.domain.hasPrefix(".")
    let host = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let address = URL(string: "http://\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)/")
    let canonical = address.flatMap(BrowserLocation.canonicalURL)?.host ?? host
    self.init(
      name: cookie.name, value: cookie.value, domain: (dotted ? "." : "") + canonical,
      path: cookie.path, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
      sameSite: cookie.sameSitePolicy?.rawValue.lowercased() ?? "unspecified",
      expires: cookie.isSessionOnly ? nil : cookie.expiresDate?.timeIntervalSince1970)
  }
  var webKitCookie: HTTPCookie? {
    let dotted = domain.hasPrefix(".")
    let host = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard let url = URL(string: "http://\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)/"),
      let mapped = BrowserAddress.proxied(url)?.host
    else { return nil }
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name, .value: value, .domain: (dotted ? "." : "") + mapped, .path: path,
      .secure: secure ? "TRUE" : "FALSE", HTTPCookiePropertyKey("HttpOnly"): httpOnly ? "TRUE" : "FALSE",
    ]
    if let expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
    if sameSite != "unspecified" { properties[.sameSitePolicy] = sameSite.capitalized }
    return HTTPCookie(properties: properties)
  }
}
