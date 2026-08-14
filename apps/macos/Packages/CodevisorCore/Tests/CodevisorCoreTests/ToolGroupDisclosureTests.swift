import Testing
@testable import CodevisorCore

@Suite("Tool group disclosure state machine")
struct ToolGroupDisclosureTests {
    private let active = ToolGroupDisclosureContext(
        hasUnsettledCall: true,
        followsLatestWork: false
    )
    private let inactive = ToolGroupDisclosureContext(
        hasUnsettledCall: false,
        followsLatestWork: false
    )

    @Test("Nested live work stays expanded after settling")
    func nestedActivityIsSticky() {
        let initial = ToolGroupDisclosureReducer.initialState(
            policy: .remainExpandedAfterActivity,
            context: active
        )
        #expect(initial == .forcedExpanded)

        let settled = ToolGroupDisclosureReducer.contextChanged(
            state: initial,
            policy: .remainExpandedAfterActivity,
            previous: active,
            current: inactive
        )
        #expect(settled == .expanded)
    }

    @Test("A live call cannot be hidden by a user toggle")
    func liveCallOwnsVisibility() {
        let state = ToolGroupDisclosureReducer.userToggled(
            state: .forcedExpanded,
            context: active
        )
        #expect(state == .forcedExpanded)
    }

    @Test("A settled nested group remains manually collapsible")
    func settledNestedGroupCanBeCollapsed() {
        let collapsed = ToolGroupDisclosureReducer.userToggled(
            state: .expanded,
            context: inactive
        )
        #expect(collapsed == .collapsed)
    }

    @Test("New activity reopens a collapsed group and leaves it open")
    func newActivityReopensGroup() {
        let forced = ToolGroupDisclosureReducer.contextChanged(
            state: .collapsed,
            policy: .remainExpandedAfterActivity,
            previous: inactive,
            current: active
        )
        #expect(forced == .forcedExpanded)

        let settled = ToolGroupDisclosureReducer.contextChanged(
            state: forced,
            policy: .remainExpandedAfterActivity,
            previous: active,
            current: inactive
        )
        #expect(settled == .expanded)
    }

    @Test("Top-level follow-latest expansion remains transient")
    func topLevelFollowLatestRemainsTransient() {
        let trailing = ToolGroupDisclosureContext(
            hasUnsettledCall: false,
            followsLatestWork: true
        )
        let initial = ToolGroupDisclosureReducer.initialState(
            policy: .followLatestWork,
            context: trailing
        )
        #expect(initial == .followingLatestWork)

        let movedOn = ToolGroupDisclosureReducer.contextChanged(
            state: initial,
            policy: .followLatestWork,
            previous: trailing,
            current: inactive
        )
        #expect(movedOn == .collapsed)
    }

    @Test("Manual top-level expansion is not an automatic close target")
    func manualExpansionSurvivesUnrelatedContextChanges() {
        let trailing = ToolGroupDisclosureContext(
            hasUnsettledCall: false,
            followsLatestWork: true
        )
        let movedOn = ToolGroupDisclosureReducer.contextChanged(
            state: .expanded,
            policy: .followLatestWork,
            previous: trailing,
            current: inactive
        )
        #expect(movedOn == .expanded)
    }

    @Test("Session store retains one disclosure object per stable group id")
    @MainActor
    func disclosureIdentitySurvivesRemount() {
        let store = TranscriptDisclosureStore()
        let first = store.toolGroupDisclosure(
            id: "group",
            policy: .remainExpandedAfterActivity,
            initialContext: active
        )
        first.reconcile(inactive)

        let remounted = store.toolGroupDisclosure(
            id: "group",
            policy: .remainExpandedAfterActivity,
            initialContext: inactive
        )
        #expect(first === remounted)
        #expect(remounted.state == .expanded)
    }
}
