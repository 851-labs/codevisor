import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2SentTokensTests {
  private static let tokens = ScreenSharingV2SentTokens(generation: ScreenSharingV2EncoderGeneration(number: 7))

  @Test func aTokenOfAnySizeComesBackForTheNumberItsFrameWasSentWith() {
    var tokens = Self.tokens
    let issued: [UInt64] = [0, 0, 1 << 32, .max]

    let sent = issued.map { tokens.sending($0, tile: 0) }

    #expect(Set(sent).count == issued.count)
    #expect(sent.map { tokens.token(acknowledgedAs: $0, tile: 0) } == issued)
    #expect(tokens.token(acknowledgedAs: sent[0], tile: 1) == nil)
  }

  @Test func onlyTheLatestTokensOfATileAreRemembered() {
    var tokens = Self.tokens
    let first = tokens.sending(1, tile: 0)
    let other = tokens.sending(2, tile: 1)

    for token in 0..<ScreenSharingV2SentTokens.remembered { _ = tokens.sending(UInt64(token), tile: 0) }

    #expect(tokens.token(acknowledgedAs: first, tile: 0) == nil)
    #expect(tokens.token(acknowledgedAs: other, tile: 1) == 2)
  }
}
