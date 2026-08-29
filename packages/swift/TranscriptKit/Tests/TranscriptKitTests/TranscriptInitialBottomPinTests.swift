import Testing
@testable import TranscriptKit

@Suite("Transcript initial bottom pin")
struct TranscriptInitialBottomPinTests {
    @Test("A fresh transcript stays pinned until its first exact presentation")
    func freshTranscriptPinsBottom() {
        var pin = TranscriptInitialBottomPin()

        pin.configure(restoresNonBottomPosition: false)
        #expect(pin.isConfigured)
        #expect(pin.isActive)

        pin.release()
        #expect(!pin.isActive)
    }

    @Test("An at-bottom cached transcript uses the same initial pin")
    func cachedBottomPinsBottom() {
        var pin = TranscriptInitialBottomPin()

        pin.configure(restoresNonBottomPosition: false)

        #expect(pin.isActive)
    }

    @Test("A non-bottom restoration keeps its saved anchor authoritative")
    func nonBottomRestorationDoesNotPin() {
        var pin = TranscriptInitialBottomPin()

        pin.configure(restoresNonBottomPosition: true)

        #expect(pin.isConfigured)
        #expect(!pin.isActive)
    }

    @Test("Later configuration cannot replace the mount's original intent")
    func configurationIsOneShot() {
        var pin = TranscriptInitialBottomPin()

        pin.configure(restoresNonBottomPosition: false)
        pin.configure(restoresNonBottomPosition: true)

        #expect(pin.isActive)
    }
}
