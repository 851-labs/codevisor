import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC

struct ScreenSharingICETests {
  @Test(arguments: [
    "stun:example.test:3478", "stuns:example.test:5349", "turn:[::1]:3478?transport=udp",
    "turn:example.test?transport=tcp", "turns:example.test:443?transport=tcp",
  ])
  func validServers(_ url: String) throws {
    #expect(ScreenSharingICEServer.validURL(url))
    _ = try ScreenSharingICEServer(urls: [url], username: "fixture", credential: "fixture")
  }
  @Test(arguments: [
    "https://example.test", "turn://example.test", "turn:user:pass@example.test", "turn:example.test/path",
    "turn:example.test:0", "turn:example.test:65536", "turn:example.test?transport=anything",
    "turns:example.test?transport=udp", "stun:example.test?transport=tcp", "turn:example.test\n",
  ])
  func invalidServers(_ url: String) {
    #expect(!ScreenSharingICEServer.validURL(url))
    #expect(throws: (any Error).self) {
      try ScreenSharingICEServer(urls: [url], username: "fixture", credential: "fixture")
    }
  }
  @Test func relayPolicyRequiresUsableBoundedCredentials() throws {
    #expect(throws: (any Error).self) { try ScreenSharingICEServer(urls: ["turn:example.test"]) }
    #expect(throws: (any Error).self) { try ScreenSharingICEConfiguration(relayOnly: true) }
    let stun = try ScreenSharingICEServer(urls: ["stun:example.test"])
    #expect(throws: (any Error).self) { try ScreenSharingICEConfiguration(servers: [stun], relayOnly: true) }
    #expect(throws: (any Error).self) { try ScreenSharingICEConfiguration(servers: Array(repeating: stun, count: 9)) }
    #expect(try ScreenSharingICEConfiguration().servers.isEmpty)
  }
}
