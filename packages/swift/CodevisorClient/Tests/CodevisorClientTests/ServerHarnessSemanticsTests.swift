import Foundation
import Testing
@testable import CodevisorClient

@Suite("Server harness semantics")
struct ServerHarnessSemanticsTests {
    @Test("Desired enablement stays independent from effective enablement")
    func desiredEnablement() throws {
        let harness = try harness(
            enabled: false,
            desiredEnabled: true,
            authState: "unauthenticated"
        )

        #expect(harness.isDesiredEnabled)
        #expect(!harness.isEffectivelyEnabled)
        #expect(harness.requiresAuthentication)
    }

    @Test("Effective enablement is the fallback for older servers")
    func legacyEnablementFallback() throws {
        let harness = try harness(enabled: true, desiredEnabled: nil, authState: nil)

        #expect(harness.isDesiredEnabled)
        #expect(harness.isEffectivelyEnabled)
        #expect(!harness.requiresAuthentication)
    }

    @Test(
        "Only authenticated and auth-free harnesses satisfy authentication",
        arguments: [
            ("authenticated", true),
            ("notRequired", true),
            ("unauthenticated", false),
            ("expired", false),
            ("checking", false),
            ("error", false),
            ("futureState", false),
        ]
    )
    func authenticationSatisfaction(state: String, expected: Bool) throws {
        let harness = try harness(enabled: false, desiredEnabled: true, authState: state)

        #expect(harness.auth?.isSatisfied == expected)
        #expect(harness.requiresAuthentication == !expected)
    }

    @Test("Unknown wire states remain distinguishable")
    func unknownStates() {
        #expect(ServerHarnessReadinessState(rawValue: "future") == .unknown("future"))
        #expect(ServerHarnessAuthenticationState(rawValue: "future") == .unknown("future"))
        #expect(ServerHarnessLifecyclePhase(rawValue: "future") == .unknown("future"))
    }

    private func harness(
        enabled: Bool,
        desiredEnabled: Bool?,
        authState: String?
    ) throws -> ServerHarness {
        var value: [String: Any] = [
            "id": "codex",
            "name": "Codex",
            "symbolName": "terminal",
            "source": "builtin",
            "launchKind": "acp",
            "enabled": enabled,
            "readiness": ["state": "ready"],
        ]
        if let desiredEnabled {
            value["desiredEnabled"] = desiredEnabled
        }
        if let authState {
            value["auth"] = [
                "state": authState,
                "accounts": [],
                "loginMethods": [],
                "supportsMultipleAccounts": true,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(ServerHarness.self, from: data)
    }
}
