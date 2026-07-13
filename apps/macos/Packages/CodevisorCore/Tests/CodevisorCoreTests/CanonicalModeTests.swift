import Testing
import ACPKit
@testable import CodevisorCore

@Suite("CanonicalMode")
struct CanonicalModeTests {
    private let state = SessionModeState(
        currentModeId: "agent",
        availableModes: [
            // Deliberately out of canonical order to prove the fixed sort.
            SessionMode(id: "agent-full-access", name: "Agent (full access)", canonicalId: "fullAccess"),
            SessionMode(id: "agent", name: "Agent", canonicalId: "ask"),
            SessionMode(id: "goal", name: "Goal mode"),
            SessionMode(id: "read-only", name: "Read-only", canonicalId: "readOnly"),
            SessionMode(id: "weird", name: "Weird", canonicalId: "someday-new")
        ]
    )

    @Test("Canonical modes sort into the fixed order with fixed labels")
    func canonicalOrdering() {
        #expect(state.canonicalModes.map(\.id) == ["read-only", "agent", "agent-full-access"])
        #expect(state.canonicalModes.map(\.displayName) == ["Read-only", "Ask", "Full access"])
    }

    @Test("Unmapped and unknown-canonical modes fall into the native section")
    func nativeOverflow() {
        // "goal" has no canonicalId; "weird" has one this app version doesn't
        // know — both degrade to native so nothing disappears.
        #expect(state.nativeOnlyModes.map(\.id) == ["goal", "weird"])
        #expect(state.nativeOnlyModes.map(\.displayName) == ["Goal mode", "Weird"])
    }

    @Test("Current mode resolves by id")
    func currentMode() {
        #expect(state.currentMode?.displayName == "Ask")
    }

    @Test("Every canonical mode has a label and symbol")
    func labelsAndSymbols() {
        for mode in CanonicalMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.symbolName.isEmpty)
        }
    }
}
