import Foundation
import Testing

@testable import CodevisorUI

@Suite("Inline plugin app URLs")
struct PluginAppViewURLTests {
  private let display = PluginAppDisplay(
    isDark: true, platform: .mobile, locale: "de-CH", mode: .pip, hostModes: [.inline, .fullscreen, .pip])

  @Test("The launch path goes through the machine's base URL and keeps its token beside the display options")
  func relayBase() throws {
    let base = try #require(URL(string: "http://127.0.0.1:51234/relay/m1/"))

    let url = PluginAppViewURL.resolve(launchPath: "/v1/plugins/apps/v%201?token=abc.def", base: base, display: display)

    let components = try #require(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    #expect(components.host == "127.0.0.1")
    #expect(components.port == 51234)
    #expect(components.percentEncodedPath == "/relay/m1/v1/plugins/apps/v%201")
    #expect(
      components.queryItems == [
        URLQueryItem(name: "token", value: "abc.def"),
        URLQueryItem(name: "theme", value: "dark"),
        URLQueryItem(name: "displayMode", value: "pip"),
        URLQueryItem(name: "modes", value: "inline,fullscreen,pip"),
        URLQueryItem(name: "platform", value: "mobile"),
        URLQueryItem(name: "locale", value: "de-CH"),
      ])
  }

  @Test("Display options replace stale ones on a reload instead of repeating them")
  func replacesDisplay() throws {
    let base = try #require(URL(string: "http://localhost:3050"))
    let light = PluginAppDisplay(isDark: false, platform: .desktop, locale: "en-US")

    let url = PluginAppViewURL.resolve(
      launchPath: "/v1/plugins/apps/v1?token=t&theme=dark&platform=mobile", base: base, display: light)

    #expect(
      url?.absoluteString
        == "http://localhost:3050/v1/plugins/apps/v1?token=t&theme=light&displayMode=inline&modes=inline&platform=desktop&locale=en-US"
    )
  }

  @Test("A launch address that would leave the machine's connection is refused")
  func refusesOtherHosts() throws {
    let base = try #require(URL(string: "http://localhost:3050"))

    #expect(PluginAppViewURL.resolve(launchPath: "https://plugin.example/app", base: base, display: display) == nil)
    #expect(PluginAppViewURL.resolve(launchPath: "//plugin.example/app", base: base, display: display) == nil)
    #expect(PluginAppViewURL.resolve(launchPath: "v1/plugins/apps/v1", base: base, display: display) == nil)
  }

  @Test("A launch is reused for ten minutes, then re-issued")
  func launchFreshness() {
    let issuedAt = Date(timeIntervalSince1970: 1_000)
    let launch = PluginAppLaunch(path: "/v1/plugins/apps/v1?token=t", issuedAt: issuedAt)

    #expect(launch.isFresh(at: issuedAt.addingTimeInterval(599)))
    #expect(!launch.isFresh(at: issuedAt.addingTimeInterval(600)))
  }
}
