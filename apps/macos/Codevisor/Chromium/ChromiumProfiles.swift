import AppKit
import CodevisorClient
import CodevisorUI

@MainActor
extension CVChromiumView {
  func cdp(_ method: String, _ params: [String: Any] = [:], sessionId: String? = nil) async throws -> [String: Any] {
    var message: [String: Any] = ["method": method, "params": params]
    if let sessionId { message["sessionId"] = sessionId }
    let json = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    let reply: String = await withCheckedContinuation { continuation in
      sendProtocol(json) { continuation.resume(returning: $0) }
    }
    let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] ?? [:]
    if let error = object["error"] as? [String: Any] {
      throw ChromiumProtocolError(error["message"] as? String ?? "Browser command failed")
    }
    return object["result"] as? [String: Any] ?? [:]
  }
}
struct ChromiumProtocolError: LocalizedError {
  var message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

@MainActor
final class ChromiumProfiles {
  static let shared = ChromiumProfiles()
  private class WeakView { weak var view: CVChromiumView?; init(_ view: CVChromiumView) { self.view = view } }
  private var views: [String: [WeakView]] = [:]
  private var syncs: [String: BrowserCookieSync] = [:]
  func attach(_ view: CVChromiumView, machineId: String, client: any CodevisorServerClienting) -> BrowserCookieSync {
    views[machineId, default: []].append(WeakView(view))
    if let sync = syncs[machineId] { sync.start(); return sync }
    let sync = BrowserCookieSync(
      client: client,
      read: { [weak self] in
        guard let view = self?.view(machineId) else { throw ChromiumProtocolError("Browser profile is closed") }
        let result = try await view.cdp("Network.getAllCookies")
        return (result["cookies"] as? [[String: Any]] ?? []).compactMap { raw in
          guard raw["partitionKey"] == nil, raw["partitionKeyOpaque"] as? Bool != true,
            let name = raw["name"] as? String, let value = raw["value"] as? String,
            let domain = raw["domain"] as? String, let path = raw["path"] as? String
          else { return nil }
          let expiry = raw["expires"] as? Double
          return BrowserCookie(
            name: name, value: value, domain: domain, path: path,
            secure: raw["secure"] as? Bool ?? false, httpOnly: raw["httpOnly"] as? Bool ?? false,
            sameSite: (raw["sameSite"] as? String)?.lowercased() ?? "unspecified",
            expires: expiry.flatMap { $0 > 0 ? $0 : nil })
        }
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
    sync.start()
    return sync
  }
  func detach(_ view: CVChromiumView?, machineId: String) {
    views[machineId] = views[machineId]?.filter { $0.view != nil && $0.view !== view }
    if views[machineId]?.isEmpty != false { syncs[machineId]?.stop() }
  }
  private func view(_ id: String) -> CVChromiumView? {
    views[id] = views[id]?.filter { $0.view?.browserIsReady == true }
    return views[id]?.first?.view
  }
}
