import SwiftUI
import CodevisorCore

extension EnvironmentValues {
  /// The session's disclosure store, injected at the transcript root. Nil in
  /// previews and detached contexts.
  @Entry public var transcriptDisclosure: TranscriptDisclosureStore?

  /// Tool-call ids of subagents that are still running after their spawning
  /// turn ended.
  @Entry public var runningSubagentToolCallIds: Set<String> = []

  /// Opens a subagent's thread as a read-only pane beside its parent chat.
  /// Must be re-injected per transcript row (rows live in cached hosts).
  @Entry public var openSubagent: OpenSubagentAction?

  /// Stable session facade used by deferred historical detail sections.
  @Entry public var transcriptController: SessionController?

  /// Runs a user disclosure change while the containing transcript row is
  /// pinned to its current viewport position.
  @Entry public var transcriptPerformAnchoredDisclosureChange: TranscriptAnchoredDisclosureChangeAction?

  /// Requests a fresh intrinsic-height measurement from the containing
  /// native transcript row after isolated SwiftUI content changes.
  @Entry public var transcriptInvalidateRowMeasurement: TranscriptRowMeasurementInvalidationAction?
}

/// Runs a disclosure change with the containing transcript row pinned in the
/// viewport. Call it like a function, as with SwiftUI's `OpenURLAction`.
public struct TranscriptAnchoredDisclosureChangeAction: Sendable {
  private let handler: @MainActor @Sendable (_ change: @escaping () -> Void) -> Void

  public init(_ handler: @escaping @MainActor @Sendable (_ change: @escaping () -> Void) -> Void) {
    self.handler = handler
  }

  @MainActor public func callAsFunction(_ change: @escaping () -> Void) { handler(change) }
}

/// Asks the containing native transcript row to re-measure its content.
public struct TranscriptRowMeasurementInvalidationAction: Sendable {
  private let handler: @MainActor @Sendable () -> Void

  public init(_ handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }

  @MainActor public func callAsFunction() { handler() }
}

/// Opens a subagent (by its spawning tool call) read-only, beside the chat
/// that started it. The host decides what that means on its platform.
public struct OpenSubagentAction: Sendable {
  public enum Placement: Sendable {
    /// The host's default: a split beside the chat on macOS, a push on iOS.
    case automatic
    case split
    case newTab
  }

  private let handler:
    @MainActor @Sendable (_ parentSessionId: UUID, _ toolCallId: String, _ title: String, _ placement: Placement)
      -> Void

  public init(
    _ handler: @escaping @MainActor @Sendable (UUID, String, String, Placement) -> Void
  ) { self.handler = handler }

  @MainActor public func callAsFunction(
    parentSessionId: UUID, toolCallId: String, title: String, placement: Placement = .automatic
  ) {
    handler(parentSessionId, toolCallId, title, placement)
  }
}
