import Foundation
import ImageIO
import Network
import Observation
import WebKit

/// WebKit has no public favicon API. Read the page's declared icons, then
/// download through its machine proxy without using the device's cookie jar.
@MainActor
@Observable
final class BrowserFaviconLoader {
  private(set) var image: CGImage?
  @ObservationIgnored var onChange: ((CGImage?) -> Void)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  func reset() {
    generation = UUID()
    task?.cancel()
    task = nil
    image = nil
    onChange?(nil)
  }

  func stop() {
    generation = UUID()
    task?.cancel()
    task = nil
  }

  func refresh(from view: WKWebView) {
    guard let page = view.url else { return }
    replace {
      guard let session = try? Self.session(for: view.configuration.websiteDataStore) else { return nil }
      defer { session.invalidateAndCancel() }
      let declared = try? await view.evaluateJavaScript(Self.discoveryScript) as? [String]
      return await Self.load(candidates: Self.candidates(declared ?? [], page: page)) { url in
        try await Self.download(url, session: session)
      }
    }
  }

  /// The generation also rejects work whose underlying API ignores cancellation.
  @discardableResult
  func replace(load: @escaping @MainActor () async -> CGImage?) -> Task<Void, Never> {
    stop()
    let token = generation
    let work = Task { [weak self] in
      guard !Task.isCancelled else { return }
      let image = await load()
      guard let self, !Task.isCancelled, self.generation == token else { return }
      self.image = image
      self.onChange?(image)
      self.task = nil
    }
    task = work
    return work
  }

  static func session(for store: WKWebsiteDataStore) throws -> URLSession {
    // An unconfigured profile must never fetch from the client machine.
    let proxies = store.proxyConfigurations
    guard !proxies.isEmpty else { throw URLError(.notConnectedToInternet) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.proxyConfigurations = proxies
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    return URLSession(configuration: configuration)
  }

  static let discoveryScript = """
    Array.from(document.querySelectorAll('link[rel]'))
      .filter(link => (link.relList.contains('icon') || link.relList.contains('apple-touch-icon'))
        && (!link.media || matchMedia(link.media).matches))
      .sort((a, b) => Number(a.type === 'image/svg+xml') - Number(b.type === 'image/svg+xml'))
      .slice(0, 16).map(link => link.href)
    """

  nonisolated static func routedURL(_ url: URL) -> URL? {
    BrowserLocation.navigationURL(url.absoluteString).flatMap(BrowserAddress.proxied)
  }

  static func candidates(_ declared: [String], page: URL) -> [URL] {
    var seen: Set<URL> = []
    return (Array(declared.prefix(16)) + ["/favicon.ico"]).compactMap { address in
      guard let url = URL(string: address, relativeTo: page)?.absoluteURL,
        let routed = routedURL(url), seen.insert(routed).inserted
      else { return nil }
      return routed
    }
  }

  static func load(candidates: [URL], download: (URL) async throws -> Data) async -> CGImage? {
    for url in candidates {
      guard !Task.isCancelled else { return nil }
      guard let data = try? await download(url), data.count <= maximumBytes,
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { continue }
      return image
    }
    return nil
  }

  private static let maximumBytes = 1_048_576

  static func download(_ url: URL, session: URLSession) async throws -> Data {
    let (bytes, response) = try await session.bytes(from: url, delegate: FaviconRedirects())
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
      response.expectedContentLength <= maximumBytes
    else { throw URLError(.badServerResponse) }
    var data = Data()
    for try await byte in bytes {
      guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
      data.append(byte)
    }
    return data
  }
}

private final class FaviconRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let url = request.url, let routed = BrowserFaviconLoader.routedURL(url) else { return nil }
    var result = request
    result.url = routed
    return result
  }
}
