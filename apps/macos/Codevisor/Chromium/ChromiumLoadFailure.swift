import CodevisorClient
import CodevisorUI
import Foundation

enum ChromiumLoadFailure {
  private static let diagnosisLimit: Duration = .seconds(2)
  private static let proxyConnectionFailed = -130

  static func pageError(
    code: Int, description: String, address: String, machine: String, client: any CodevisorServerClienting
  ) async -> BrowserPageError {
    let failure = await proxyFailure(code: code, address: address, client: client)
    return .load(code: code, description: description, url: address, machine: machine, proxyFailure: failure)
  }

  static func restartsBrowser(code: Int) -> Bool { code == proxyConnectionFailed }

  private static func proxyFailure(
    code: Int, address: String, client: any CodevisorServerClienting
  ) async -> String? {
    guard BrowserPageError.needsProxyDiagnosis(code: code), let authority = authority(of: address) else { return nil }
    var failure: String?
    await ChromiumDeadline.run(within: diagnosisLimit) {
      failure = try? await client.browserProxyFailure(authority: authority)
    }
    return failure
  }

  private static func authority(of address: String) -> String? {
    guard let url = URL(string: address), let host = url.host() else { return nil }
    let port = url.port ?? (url.scheme == "https" ? 443 : 80)
    return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }
}
