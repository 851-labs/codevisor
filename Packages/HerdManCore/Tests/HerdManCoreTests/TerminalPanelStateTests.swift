import Foundation
import Testing
@testable import HerdManCore

@Suite("TerminalPanelState")
struct TerminalPanelStateTests {
    @Test("Defaults are hidden at the default height")
    func defaults() {
        let state = TerminalPanelState()
        #expect(!state.isVisible)
        #expect(state.height == TerminalPanelState.defaultHeight)
    }

    @Test("Toggle opens and focuses the terminal, then closes and focuses the composer")
    func toggle() {
        var state = TerminalPanelState()
        #expect(state.toggle() == .terminal)
        #expect(state.isVisible)
        #expect(state.toggle() == .composer)
        #expect(!state.isVisible)
    }

    @Test("Height is clamped to the allowed range")
    func clamping() {
        var state = TerminalPanelState()
        state.setHeight(10_000)
        #expect(state.height == TerminalPanelState.maxHeight)
        state.setHeight(0)
        #expect(state.height == TerminalPanelState.minHeight)
        state.setHeight(300)
        #expect(state.height == 300)
    }

    @Test("Initializer clamps the provided height")
    func initClamps() {
        #expect(TerminalPanelState(height: -5).height == TerminalPanelState.minHeight)
        #expect(TerminalPanelState(height: 5_000).height == TerminalPanelState.maxHeight)
    }
}
