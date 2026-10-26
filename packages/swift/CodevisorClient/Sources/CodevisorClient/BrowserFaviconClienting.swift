import Foundation

public protocol BrowserFaviconClienting: Sendable {
  func browserFavicon(sha256: String) async throws -> Data?
  func publishBrowserFavicon(sha256: String, png: Data) async throws
}
