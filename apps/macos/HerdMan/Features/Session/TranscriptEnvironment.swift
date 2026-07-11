import SwiftUI
import HerdManCore

extension EnvironmentValues {
    /// The session's disclosure store, injected at the transcript root. Nil in
    /// previews and detached contexts.
    @Entry var transcriptDisclosure: TranscriptDisclosureStore?

    /// Tool-call ids of subagents that are still running after their spawning
    /// turn ended.
    @Entry var runningSubagentToolCallIds: Set<String> = []

    /// Stable session facade used by deferred historical detail sections.
    @Entry var transcriptController: SessionController?

    /// Runs a user disclosure change while the containing transcript row is
    /// pinned to its current viewport position.
    @Entry var transcriptPerformAnchoredDisclosureChange: ((@escaping () -> Void) -> Void)?
}
