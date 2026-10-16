import CoreGraphics
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use click options and waiting")
struct ComputerUseClickOptionsTests {
  @Test("Modifier chords map to event flags and reject ordinary keys")
  func modifierFlags() throws {
    #expect(try computerUseModifierFlags("shift") == .maskShift)
    #expect(try computerUseModifierFlags("cmd+Shift") == [.maskCommand, .maskShift])
    #expect(try computerUseModifierFlags("super + alt + ctrl") == [.maskCommand, .maskAlternate, .maskControl])
    #expect(throws: BridgeError.self) { try computerUseModifierFlags("shift+a") }
  }

  @Test("A held click accepts 0 to 10 seconds")
  func holdDuration() throws {
    #expect(try computerUseHoldSeconds(nil) == 0)
    #expect(try computerUseHoldSeconds(1_500) == 1.5)
    #expect(throws: BridgeError.self) { try computerUseHoldSeconds(10_001) }
    #expect(throws: BridgeError.self) { try computerUseHoldSeconds(-1) }
  }

  @Test("Observations keep waiting on a loading indicator for up to 5 seconds after an action")
  func loadingWindow() {
    #expect(computerUseLoadingWindow(sinceAction: nil) == 0)
    #expect(computerUseLoadingWindow(sinceAction: 1) == 4)
    #expect(computerUseLoadingWindow(sinceAction: 6) == 0)
  }

  @Test("Removed element indexes are summarized as ranges")
  func idRanges() {
    #expect(computerUseIDRanges([3, 4, 5, 9, 11, 12]) == "3-5, 9, 11-12")
    #expect(computerUseIDRanges([7]) == "7")
  }
}
