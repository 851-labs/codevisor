import Testing

@testable import SimulatorPane

@Suite struct SimulatorKeyboardTests {
  @Test func charactersTypeTheirKeyOnTheSimulatorsUSKeyboard() {
    // Typed text is mapped by character, so a Mac on another layout (or text sent without real
    // key codes) still types what was meant.
    #expect(SimulatorKeyboard.key(for: "a")! == (0x04, false))
    #expect(SimulatorKeyboard.key(for: "A")! == (0x04, true))
    #expect(SimulatorKeyboard.key(for: "0")! == (0x27, false))
    #expect(SimulatorKeyboard.key(for: "!")! == (0x1E, true))
    #expect(SimulatorKeyboard.key(for: "?")! == (0x38, true))
    #expect(SimulatorKeyboard.key(for: ".")! == (0x37, false))
    #expect(SimulatorKeyboard.key(for: "é") == nil)
  }
}
