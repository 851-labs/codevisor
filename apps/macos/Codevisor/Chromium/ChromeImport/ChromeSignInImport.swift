import CodevisorClient
import CodevisorCoreMac
import CodevisorUI
import Foundation
import Observation

@Observable
final class ChromeSignInImport {
  static let shared = ChromeSignInImport()
  private static let importedDisplay: Duration = .seconds(2)

  enum Phase: Equatable {
    case idle
    case importing
    case imported
    case failed(String)
  }

  private(set) var profiles = ChromeProfiles.empty
  private(set) var phase = Phase.idle

  var isImporting: Bool { phase == .importing }
  var failure: String? {
    guard case .failed(let message) = phase else { return nil }
    return message
  }

  func loadProfiles() async {
    profiles = await ChromeProfiles.load()
  }

  @discardableResult
  func importSignIns(from profile: ChromeProfile, into browser: ChromiumBrowserModel) async -> Bool {
    guard !isImporting else { return false }

    phase = .importing
    do {
      try await Self.send(try await Self.read(profile), to: browser)
    } catch {
      phase = .failed(Self.message(for: error))
      return false
    }
    ChromiumBrowserModels.shared.reload(machineId: browser.machineId)
    showImported()
    return true
  }

  func clearFailure() {
    guard failure != nil else { return }
    phase = .idle
  }

  private func showImported() {
    phase = .imported
    Task { [weak self] in
      try? await Task.sleep(for: Self.importedDisplay)
      guard self?.phase == .imported else { return }
      self?.phase = .idle
    }
  }

  @concurrent
  private nonisolated static func read(_ profile: ChromeProfile) async throws -> [BrowserCookie] {
    let cipher = try ChromeCookieCipher.unlock()
    return try await ChromeCookieReader.cookies(in: profile, cipher: cipher)
  }

  private static func send(_ cookies: [BrowserCookie], to browser: ChromiumBrowserModel) async throws {
    _ = try await browser.client.importBrowserCookies(cookies)
    _ = try? await ChromiumProfiles.shared.cookieSync(machineId: browser.machineId)?.synchronize()
  }

  private static func message(for error: any Error) -> String {
    (error as? ChromeImportError)?.errorDescription ?? "Couldn’t import Chrome sign-ins."
  }
}
