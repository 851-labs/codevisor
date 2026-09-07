import Foundation

public protocol BrowserStateClienting: Sendable {
  func exchangeBrowserCookies(_ mutations: [BrowserCookieMutation]) async throws -> BrowserCookieSnapshot
  func browserNavigation(paneId: UUID) async throws -> BrowserNavigation?
  func publishBrowserNavigation(paneId: UUID, navigation: BrowserNavigation) async throws
}
