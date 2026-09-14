import CodevisorClient
import Foundation
import Testing
@testable import CodevisorCoreMac

struct ScreenSharingConnectivityTests {
  @Test func defaultConfigurationDoesNotContactThirdPartyServers() throws {
    let result = try ScreenSharingHostConnectivity(environment: [:], now: { 1_700_000_000 }).make(viewerId: UUID())
    #expect(result.servers.isEmpty && !result.relayOnly)
  }

  @Test func credentialsUseTURNRESTHMACAndExpireWithoutExposingTheSharedSecret() throws {
    let configuration = ScreenSharingHostConnectivity(
      environment: [
        "CODEVISOR_SCREEN_SHARING_STUN_URLS": "stun:relay.example.test:3478",
        "CODEVISOR_SCREEN_SHARING_TURN_URLS":
          "turn:relay.example.test:3478?transport=udp, turns:relay.example.test:443?transport=tcp",
        "CODEVISOR_SCREEN_SHARING_TURN_SECRET": "fixture-secret",
        "CODEVISOR_SCREEN_SHARING_RELAY_ONLY": "1",
      ], now: { 1_700_000_000 })
    let result = try configuration.make(viewerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    #expect(result.expiresAt == 1_700_000_300)
    #expect(result.relayOnly)
    #expect(result.servers[1].credential == "IAVGLGXf33m6RhQKjUfVHiRskOc=")
    #expect(result.servers[1].username == "1700000300:codevisor:00000000-0000-0000-0000-000000000001")
    let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    #expect(!wire.contains("fixture-secret"))
    let other = try configuration.make(viewerId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    #expect(other.servers[1].credential != result.servers[1].credential)
  }

  @Test func incompleteOrMalformedRelayConfigurationFailsBeforeCreatingAPeer() {
    for environment in [
      ["CODEVISOR_SCREEN_SHARING_TURN_URLS": "turn:relay.example.test"],
      ["CODEVISOR_SCREEN_SHARING_RELAY_ONLY": "1"],
      ["CODEVISOR_SCREEN_SHARING_RELAY_ONLY": "typo"],
      ["CODEVISOR_SCREEN_SHARING_STUN_URLS": "https://example.test"],
    ] {
      #expect(throws: (any Error).self) {
        try ScreenSharingHostConnectivity(environment: environment, now: { 1_700_000_000 }).make(viewerId: UUID())
      }
    }
  }
}
