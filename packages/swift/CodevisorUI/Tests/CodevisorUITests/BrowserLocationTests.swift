import Foundation
import Testing
@testable import CodevisorUI

@Suite("Independent browser locations")
struct BrowserLocationTests {
  @Test(arguments: [
    ("localhost:3000", "http://localhost:3000"),
    ("127.0.0.2:3001/api", "http://127.0.0.2:3001/api"),
    ("[::1]:3000", "http://[::1]:3000"),
    ("http://proxy.localhost:3000/a", "http://localhost:3000/a"),
    ("http://ipv4-127-0-0-2.proxy.localhost:3001", "http://127.0.0.2:3001"),
    ("http://ipv6.proxy.localhost:3001", "http://[::1]:3001"),
  ])
  func canonicalAddresses(input: String, expected: String) {
    #expect(BrowserLocation.navigationURL(input)?.absoluteString == expected)
    #expect(BrowserLocation.addressBarURL(input)?.absoluteString == expected)
  }

  @Test(arguments: [
    "https://site.example/callback?code=once&state=browser",
    "https://site.example/#access_token=secret",
    "https://site.example/?oauth_verifier=once",
    "https://site.example/?SAMLResponse=secret",
    "https://site.example/?password=secret",
  ])
  func authenticationLocationsAreNeverPublished(address: String) {
    #expect(BrowserLocation.sharedURL(address) == nil)
  }

  @Test func ordinaryLocationsCanSeedAnotherBrowser() {
    #expect(
      BrowserLocation.sharedURL("http://proxy.localhost:3000/search?q=cats#results")?.absoluteString
        == "http://localhost:3000/search?q=cats#results")
    #expect(BrowserLocation.display(URL(string: "http://localhost:3000/a?b=1")!) == "localhost:3000")
    #expect(BrowserLocation.addressBarURL("cats")?.host == "www.google.com")
  }
}
