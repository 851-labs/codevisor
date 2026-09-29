import ACPKit
import CodevisorCore
import SwiftUI

/// A subagent in the transcript: one row, laid out like the tool rows around
/// it — the harness's icon and the agent's name, shimmering while it works. Its
/// thread opens separately through `openSubagent` (a pane beside the chat on
/// macOS, a pushed screen on iOS) instead of nesting inline.
public struct SubagentRow: View {
  let call: ToolCall
  let isTurnActive: Bool

  public init(call: ToolCall, isTurnActive: Bool) {
    self.call = call
    self.isTurnActive = isTurnActive
  }

  @Environment(\.openSubagent) private var openSubagent
  @Environment(\.transcriptController) private var transcriptController
  @Environment(\.runningSubagentToolCallIds) private var runningSubagentToolCallIds
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  // ToolGroupView's metrics, so the rows share one icon column.
  private static var iconSize: CGFloat {
    #if os(iOS)
      15
    #else
      12
    #endif
  }

  private static var iconColumnWidth: CGFloat {
    #if os(iOS)
      18
    #else
      16
    #endif
  }

  private static var spacing: CGFloat {
    #if os(iOS)
      6
    #else
      8
    #endif
  }

  /// Running while the turn is live and the call is open, or — after the
  /// turn ended — while the harness still reports it as a background task.
  private var isRunning: Bool {
    (isTurnActive && !call.isSettled) || runningSubagentToolCallIds.contains(call.toolCallId)
  }

  private var title: String {
    // A placeholder for work after a follow-up takes its agent's name.
    if call.rawInput == nil, let transcriptController,
      let spawn = SubagentMirror.spawn(of: call.toolCallId, in: transcriptController)
    {
      return SubagentMirror.title(of: spawn)
    }
    return SubagentMirror.title(of: call)
  }

  /// Subagents run in their chat's harness.
  private var harnessId: String? {
    transcriptController?.serverSession?.harnessId ?? transcriptController?.activeHarnessId
  }

  /// The chat that owns this row. Nil inside a subagent's own read-only
  /// view, whose mirror controller isn't a chat: nested agents don't open.
  private var parentSessionId: UUID? { transcriptController?.serverSession?.id }

  private var canOpen: Bool { openSubagent != nil && parentSessionId != nil }

  public var body: some View {
    if canOpen {
      Button {
        open(.automatic)
      } label: {
        label
      }
      .buttonStyle(.plain)
      .onHover { isHovered = $0 }
      #if os(macOS)
        .contextMenu {
          Button("Open in Split View", systemImage: "rectangle.righthalf.inset.filled") { open(.split) }
          Button("Open in New Tab", systemImage: "plus.square.on.square") { open(.newTab) }
        }
      #endif
      .accessibilityValue(statusDescription)
      .accessibilityHint("Shows the agent's conversation")
    } else {
      label
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusDescription)
    }
  }

  private var label: some View {
    HStack(spacing: Self.spacing) {
      HarnessGlyph(harnessId: harnessId, fallbackSymbolName: "wand.and.sparkles", size: Self.iconSize)
        .foregroundStyle(.secondary)
        .frame(width: Self.iconColumnWidth)
        .accessibilityHidden(true)
      Text(title)
        .foregroundStyle(.secondary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        .truncationMode(.tail)
        .shimmering(isRunning)
      statusGlyph
      if canOpen {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(isHovered ? .secondary : .tertiary)
          .frame(width: 10, height: 10)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var statusGlyph: some View {
    switch call.status {
    case .failed:
      Image(systemName: "xmark.circle")
        .font(.caption)
        .foregroundStyle(theme.statusError)
        .accessibilityHidden(true)
    case .cancelled:
      Image(systemName: "slash.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    default:
      EmptyView()
    }
  }

  private var statusDescription: String {
    if isRunning { return "Running" }
    switch call.status {
    case .failed: return "Failed"
    case .cancelled: return "Stopped"
    default: return "Done"
    }
  }

  private func open(_ placement: OpenSubagentAction.Placement) {
    guard let openSubagent, let parentSessionId else { return }
    openSubagent(parentSessionId: parentSessionId, toolCallId: call.toolCallId, title: title, placement: placement)
  }
}
