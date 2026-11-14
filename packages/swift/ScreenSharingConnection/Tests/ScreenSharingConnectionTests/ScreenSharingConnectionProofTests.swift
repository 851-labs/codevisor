import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import Testing

@MainActor
@Suite("Screen share connection: proving the app's key", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionProofTests {
  @Test("A start is signed once, over the frozen eight lines, with the nonce from this attempt's capabilities")
  func signsTheStart() async throws {
    let harness = ConnectionHarness()
    harness.connection.preferredDisplayId = FakeHost.display.id
    harness.open(.tab)
    await harness.goLive()

    let start = try #require(harness.host.starts.first)
    let expected = [
      "codevisor.screen-sharing.start.v1", "start", FakeHost.grant.endpointId, FakeHost.token(1),
      FakeMedia.address.endpointId, start.viewerId.uuidString.lowercased(), "open", FakeHost.display.id,
    ]
    #expect(harness.signer.messages == [expected.joined(separator: "\n")])
    #expect(
      start.proof == ServerScreenSharingProof(nonce: FakeHost.token(1), signature: FakeSigner.signature(number: 1)))
  }

  @Test("A start with no display chosen signs an empty last line")
  func signsAnEmptyTarget() async throws {
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()

    let message = try #require(harness.signer.messages.first)
    #expect(
      message.hasSuffix("\nattach\n") && message.split(separator: "\n", omittingEmptySubsequences: false).count == 8)
  }

  enum Unusable: CaseIterable, Sendable { case missing, upperCaseHostKey, shortHostKey, nonHexNonce }

  @Test(
    "A host whose challenge is missing or isn't two 64-character lowercase hex strings is treated as an old host",
    arguments: Unusable.allCases)
  func needsAUsableChallengeToUseTheAppIdentity(_ challenge: Unusable) async throws {
    let harness = ConnectionHarness()
    switch challenge {
    case .missing: harness.host.mintsChallenges = false
    case .upperCaseHostKey: harness.host.challengeHostKey = String(repeating: "B", count: 64)
    case .shortHostKey: harness.host.challengeHostKey = String(repeating: "b", count: 63)
    case .nonHexNonce: harness.host.forgedNonce = String(repeating: "g", count: 64)
    }
    harness.show()
    await harness.goLive()

    let start = try #require(harness.host.starts.first)
    #expect(start.app == nil && start.proof == nil && harness.signer.messages.isEmpty)
    #expect(harness.host.registeredPanes == [harness.legacyIdentity(harness.workspaces[0])])
  }

  @Test(
    "A rejected proof is answered by signing the fresh challenge, at most twice; after that the connect fails",
    arguments: 1...3)
  func signsAgainWhenTheProofIsRejected(rejections: Int) async {
    let message = "The request couldn't be verified."
    let harness = ConnectionHarness()
    for _ in 1...rejections {
      harness.host.answerNext(.start, .reply(status: "failed", message: message, reason: "proof-rejected"))
    }
    harness.show()
    if rejections < 3 {
      await harness.goLive()
    } else {
      await harness.settle(.failed(.unclassified(message: message)))
    }

    let nonces = harness.host.starts.compactMap(\.proof?.nonce)
    #expect(harness.host.starts.count == min(rejections + 1, 3) && Set(nonces).count == nonces.count)
    #expect(Set(harness.host.starts.map(\.viewerId)).count == 1, "the resends belong to one attempt")
    #expect(harness.signer.messages.count == harness.host.starts.count)
  }

  @Test("A signed start the relay interrupts is never sent again as it was: a fresh challenge is signed instead")
  func neverResendsASignedStart() async {
    let harness = ConnectionHarness()
    harness.host.answerNext(.start, .failure(FakeHost.interrupted))
    harness.show()
    await harness.goLive()

    let proofs = harness.host.starts.compactMap(\.proof)
    #expect(harness.host.requests(.capabilities).count == 2)
    #expect(proofs.count == 2 && proofs[0].nonce != proofs[1].nonce && proofs[0].signature != proofs[1].signature)
    #expect(harness.host.stops.isEmpty, "the connection never failed in between")
  }

  @Test("If the granted video address isn't the host that was challenged, no video is connected and the connect fails")
  func refusesVideoFromAnotherHost() async {
    let harness = ConnectionHarness()
    harness.host.challengeHostKey = String(repeating: "c", count: 64)
    harness.show()
    await harness.settle(.failed(.unclassified(message: Self.wrongHost)))
    await awaitObserved { harness.host.stops.count == 1 }

    #expect(harness.media.sessions.isEmpty)
    #expect(harness.host.stops[0].session == FakeHost.token(2), "the session the host granted is stopped")
  }

  @Test("If the app can't sign, the connect fails with that error and never falls back to a pane identity")
  func failsWhenTheSignerFails() async {
    let harness = ConnectionHarness()
    harness.signer.failFromNowOn()
    harness.show()
    await harness.settle(.failed(.unclassified(message: "The app's key couldn't be read in this test.")))

    #expect(harness.host.starts.isEmpty && harness.host.registeredPanes.isEmpty)
  }

  private static let wrongHost =
    "The video address doesn't belong to the machine that was asked, so nothing was connected. Retry."
}
