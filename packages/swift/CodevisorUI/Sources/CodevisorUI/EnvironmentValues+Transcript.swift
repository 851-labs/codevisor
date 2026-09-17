import SwiftUI
import CodevisorCore

extension EnvironmentValues {
  /// The session's disclosure store, injected at the transcript root. Nil in
  /// previews and detached contexts.
  @Entry public var transcriptDisclosure: TranscriptDisclosureStore?

  /// Tool-call ids of subagents that are still running after their spawning
  /// turn ended.
  @Entry public var runningSubagentToolCallIds: Set<String> = []

  /// Stable session facade used by deferred historical detail sections.
  @Entry public var transcriptController: SessionController?

  /// Runs a user disclosure change while the containing transcript row is
  /// pinned to its current viewport position.
  @Entry public var transcriptPerformAnchoredDisclosureChange: ((@escaping () -> Void) -> Void)?

  /// Requests a fresh intrinsic-height measurement from the containing
  /// native transcript row after isolated SwiftUI content changes.
  @Entry public var transcriptInvalidateRowMeasurement: (() -> Void)?
}
