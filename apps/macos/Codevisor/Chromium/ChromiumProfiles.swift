import AppKit
import CodevisorClient
import CodevisorUI

typealias ChromiumProtocolError = BrowserProtocolError

extension CVChromiumView {
  /// Hands one pre-encoded command to CEF, which accepts it only on its UI
  /// (main) thread, and returns the raw reply. Nothing is parsed here.
  func protocolReply(_ method: String, params: Data? = nil, sessionId: String? = nil) async -> Data {
    await withCheckedContinuation { continuation in
      sendProtocolMethod(method, params: params, sessionId: sessionId) { continuation.resume(returning: $0) }
    }
  }

  /// Encodes and decodes on the caller's executor; only the hand-off to CEF
  /// runs on the main actor. Use `protocolReply` for large results.
  nonisolated func cdp(
    _ method: String, _ params: [String: Any] = [:], sessionId: String? = nil
  ) async throws
    -> [String: Any]
  {
    let body = try JSONSerialization.data(withJSONObject: params)
    let reply = await protocolReply(method, params: body, sessionId: sessionId)
    let result = try BrowserProtocolMessage.result(ofReply: reply)
    return try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:]
  }
}

@MainActor
final class ChromiumProfiles {
  static let shared = ChromiumProfiles()
  private class WeakView { weak var view: CVChromiumView?; init(_ view: CVChromiumView) { self.view = view } }
  private var views: [String: [WeakView]] = [:]
  private var syncs: [String: BrowserCookieSync] = [:]
  private var cookieReplies: [String: BrowserProtocolCookies] = [:]
  private var visiblePanes: [String: Set<UUID>] = [:]

  func attach(_ view: CVChromiumView, machineId: String, client: any CodevisorServerClienting) -> BrowserCookieSync {
    views[machineId, default: []].append(WeakView(view))
    if let sync = syncs[machineId] { sync.start(); return sync }
    let sync = BrowserCookieSync(
      client: client,
      read: { [weak self] in
        guard let self, let view = self.view(machineId) else {
          throw ChromiumProtocolError("Browser profile is closed")
        }
        let reply = await view.protocolReply("Network.getAllCookies")
        let (cookies, cache) = try await Self.decodeCookies(reply, cache: cookieReplies[machineId] ?? .init())
        cookieReplies[machineId] = cache
        return cookies
      },
      apply: { [weak self] cookie, previous in
        guard let view = self?.view(machineId) else { throw ChromiumProtocolError("Browser profile is closed") }
        if let previous {
          _ = try await view.cdp(
            "Network.deleteCookies", ["name": previous.name, "domain": previous.domain, "path": previous.path])
        }
        if let cookie {
          var params: [String: Any] = [
            "name": cookie.name, "value": cookie.value, "path": cookie.path,
            "secure": cookie.secure, "httpOnly": cookie.httpOnly,
          ]
          // CDP's domain parameter creates a domain cookie. A URL preserves host-only cookies.
          if cookie.domain.hasPrefix(".") {
            params["domain"] = cookie.domain
          } else {
            params["url"] = "\(cookie.secure ? "https" : "http")://\(cookie.domain)\(cookie.path)"
          }
          if let expires = cookie.expires { params["expires"] = expires }
          if cookie.sameSite != "unspecified" { params["sameSite"] = cookie.sameSite.capitalized }
          let result = try await view.cdp("Network.setCookie", params)
          if result["success"] as? Bool == false { throw ChromiumProtocolError("Browser could not import a cookie") }
        }
      })
    syncs[machineId] = sync
    sync.setVisible(visiblePanes[machineId]?.isEmpty == false)
    sync.start()
    return sync
  }
  func detach(_ view: CVChromiumView?, machineId: String) {
    views[machineId] = views[machineId]?.filter { $0.view != nil && $0.view !== view }
    if views[machineId]?.isEmpty != false { syncs[machineId]?.stop() }
  }
  /// A profile with no page on screen polls cookies rarely.
  func setVisible(_ visible: Bool, paneId: UUID, machineId: String) {
    if visible { visiblePanes[machineId, default: []].insert(paneId) } else { visiblePanes[machineId]?.remove(paneId) }
    syncs[machineId]?.setVisible(visiblePanes[machineId]?.isEmpty == false)
  }
  private func view(_ id: String) -> CVChromiumView? {
    views[id] = views[id]?.filter { $0.view?.browserIsReady == true }
    return views[id]?.first?.view
  }
  @concurrent
  private nonisolated static func decodeCookies(
    _ reply: Data, cache: BrowserProtocolCookies
  ) async throws
    -> ([BrowserCookie], BrowserProtocolCookies)
  {
    var cache = cache
    return (try cache.cookies(fromReply: reply), cache)
  }
}
