import Testing
@testable import TranscriptKit

@Suite("Transcript initial bottom pin")
struct TranscriptInitialBottomPinTests {
  @Test("A fresh transcript stays pinned until its first exact presentation")
  func freshTranscriptPinsBottom() {
    var pin = TranscriptInitialBottomPin()

    pin.configure(restoresNonBottomPosition: false)
    #expect(pin.isActive)

    pin.release()
    #expect(!pin.isActive)
  }
}
