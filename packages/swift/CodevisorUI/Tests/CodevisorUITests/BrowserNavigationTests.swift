import Foundation
import Testing
@testable import CodevisorUI

@MainActor
@Suite("Browser navigation")
struct BrowserNavigationTests {
  @Test(arguments: [
    ("https://www.emojis.com/create?q=cat#result", "emojis.com"),
    ("https://shop.example.co.uk/orders", "shop.example.co.uk"),
    ("https://www.example.com:443/path", "example.com"),
    ("http://localhost:3000/path", "localhost:3000"),
    ("http://ipv6.proxy.localhost:61334/", "ipv6.proxy.localhost:61334"),
    ("http://[::1]:3000/path", "[::1]:3000"),
    ("https://example.com.attacker.test/path", "example.com.attacker.test"),
  ])
  func shortenedAddressPreservesOrigin(input: String, expected: String) throws {
    let url = try #require(URL(string: input))
    #expect(BrowserAddress.display(url) == expected)
    #expect(url.absoluteString == input)
  }

  @Test(arguments: [
    (" localhost:3000/app?x=1 ", "http://proxy.localhost:3000/app?x=1"),
    ("127.0.0.1:8080", "http://ipv4-127-0-0-1.proxy.localhost:8080"),
    ("[::1]:3000", "http://ipv6.proxy.localhost:3000"),
    ("example.com", "https://example.com"),
    ("http://example.com/path", "http://example.com/path"),
  ])
  func normalize(input: String, expected: String) {
    #expect(BrowserPaneModel.navigationURL(input)?.absoluteString == expected)
    #expect(BrowserPaneModel.addressBarURL(input)?.absoluteString == expected)
  }

  @Test(arguments: [
    "bananas", "  not an address\n", "swift webkit browser", "C++ & Swift #examples",
    "café 🐈", "site:emojis.com cats", "site:emojis.com", "how to use https://example.com",
  ])
  func searchesGoogle(input: String) throws {
    let url = try #require(BrowserPaneModel.addressBarURL(input))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "https")
    #expect(components.host == "www.google.com")
    #expect(components.path == "/search")
    let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(components.queryItems == [URLQueryItem(name: "q", value: query)])
    #expect(components.fragment == nil)
    #expect(components.percentEncodedQuery?.contains("+") == false)
  }

  @Test(arguments: [
    ("localhost", "http://proxy.localhost"),
    ("devbox:3000/path", "http://devbox:3000/path"),
    ("192.168.1.10:8080", "http://192.168.1.10:8080"),
    ("https://intranet", "https://intranet"),
    ("example.com/search?q=cat#results", "https://example.com/search?q=cat#results"),
  ])
  func addressesStayDirect(input: String, expected: String) {
    #expect(BrowserPaneModel.addressBarURL(input)?.absoluteString == expected)
  }

  @Test(arguments: [
    "", " \n ", "file:///etc/passwd", "javascript://alert(1)",
    "https://user:password@example.com", "http://localhost:0", "http://localhost:65536",
  ])
  func invalidExplicitAddressesDoNotBecomeSearches(input: String) {
    #expect(BrowserPaneModel.addressBarURL(input) == nil)
  }

  @Test(arguments: [
    "", "not an address", "file:///etc/passwd", "javascript://alert(1)",
    "https://user:password@example.com", "http://localhost:0", "http://localhost:65536",
  ])
  func rejectsUnsupportedAddresses(input: String) {
    #expect(BrowserPaneModel.navigationURL(input) == nil)
  }
}
