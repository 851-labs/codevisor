import ACPKit
import SwiftUI
import TranscriptKit

/// One line of the worked timeline: a node on a vertical rail beside the
/// line, with whatever the line opens below it. The rail runs through the
/// row, so the abutting rows of a worked section join it into one line.
struct WorkedTimelineRail<Node: View, Line: View, Expanded: View>: View {
  let isFirst: Bool
  let isLast: Bool
  /// Hover and taps on the header row alone (its node and line), never on
  /// what it opens.
  var onHeaderHover: ((Bool) -> Void)? = nil
  var onHeaderTap: (() -> Void)? = nil
  @ViewBuilder let node: () -> Node
  @ViewBuilder let line: () -> Line
  @ViewBuilder let expanded: () -> Expanded

  private let lineHeight: CGFloat = 18
  private let nodeWidth: CGFloat = 18
  private let verticalPadding = TranscriptTimelineMarks.linePadding
  /// How far the rail stops short of the node's center: half a tool icon,
  /// plus clearance.
  private let railGap = ToolIconMetrics.artworkSide / 2 + TranscriptTimelineMarks.nodeClearance

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      expanded()
        .padding(.leading, nodeWidth + 8)
    }
    .padding(.vertical, verticalPadding)
    .background(alignment: .topLeading) {
      GeometryReader { proxy in
        Path { path in
          let x = nodeWidth / 2
          if !isFirst {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: TranscriptTimelineMarks.nodeCenterY - railGap))
          }
          if !isLast {
            path.move(to: CGPoint(x: x, y: TranscriptTimelineMarks.nodeCenterY + railGap))
            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
          }
        }
        .stroke(Color.primary.opacity(0.18), lineWidth: TranscriptTimelineMarks.railWidth)
      }
    }
  }

  /// The node sits on the line's first baseline and the line hangs from
  /// the top, so a line that wraps grows downward without moving. The
  /// node's slot is a hidden line of text, so its size and baseline never
  /// depend on what it shows (an icon, or a chevron on hover).
  @ViewBuilder
  private var header: some View {
    let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(" ")
        .hidden()
        .frame(width: nodeWidth)
        .overlay { node() }
      line()
        .frame(minHeight: lineHeight, alignment: .topLeading)
    }
    .contentShape(Rectangle())
    .onHover { onHeaderHover?($0) }
    if let onHeaderTap {
      row
        .onTapGesture(perform: onHeaderTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onHeaderTap() }
    } else {
      row
    }
  }
}

/// A worked note's Markdown row on its section's timeline: its text inset
/// past the rail, the rail through it, and the note's dot on its first line.
struct WorkedTimelineGutter: ViewModifier {
  let marks: TranscriptTimelineMarks?

  func body(content: Content) -> some View {
    if let marks {
      content
        .padding(.leading, TranscriptTimelineMarks.gutterWidth)
        .padding(.top, marks.startsLine ? TranscriptTimelineMarks.linePadding : 0)
        .padding(.bottom, marks.endsLine ? TranscriptTimelineMarks.linePadding : 0)
        .background(alignment: .topLeading) {
          GeometryReader { proxy in
            let x = TranscriptTimelineMarks.railX
            let dotY = TranscriptTimelineMarks.nodeCenterY
            let gap = TranscriptTimelineMarks.dotDiameter / 2 + TranscriptTimelineMarks.nodeClearance
            Path { path in
              if marks.railAbove {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: marks.startsLine ? dotY - gap : proxy.size.height))
              }
              if marks.railBelow {
                path.move(to: CGPoint(x: x, y: marks.startsLine ? dotY + gap : 0))
                path.addLine(to: CGPoint(x: x, y: proxy.size.height))
              }
            }
            .stroke(Color.primary.opacity(0.18), lineWidth: TranscriptTimelineMarks.railWidth)
            if marks.startsLine {
              Circle()
                .fill(.secondary)
                .frame(width: TranscriptTimelineMarks.dotDiameter, height: TranscriptTimelineMarks.dotDiameter)
                .position(x: x, y: dotY)
            }
          }
        }
    } else {
      content
    }
  }
}

/// A rail node: a dot for the model's notes, the icon of a group's latest
/// call, or the line's disclosure chevron while it is hovered or open.
struct WorkedTimelineNode: View {
  let item: WorkedItem
  var showsChevron = false
  var isExpanded = false

  var body: some View {
    if showsChevron {
      TranscriptDisclosureChevron(expanded: isExpanded)
    } else {
      switch item {
      case .text:
        Circle()
          .fill(.secondary)
          .frame(width: 5, height: 5)
      case let .toolGroup(group):
        if let latest = group.calls.last {
          ToolCallIconView(icon: latest.icon)
        }
      case .subagents:
        Image(systemName: "wand.and.sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

extension EnvironmentValues {
  /// Tool rows brighten their title on hover when they open, as the worked
  /// timeline's own lines do.
  @Entry var toolRowsHighlightOnHover = false
}

enum WorkedTimelineText {
  /// A group of calls or agents in a few words: the group's summary, or
  /// what became of its agents. The turn waits on an agent it runs in the
  /// foreground ("Waiting for Map the UI"), then has run it ("Ran an
  /// agent"); one sent to the background, or still running while the turn
  /// works on, was only started ("Started 2 agents").
  static func title(calls: [ToolCall], agents: [ToolCall], awaited: [ToolCall]) -> String {
    guard calls.isEmpty else { return ToolCallSummary.describe(calls) }
    let waitedOn = agents.filter { agent in awaited.contains { $0.toolCallId == agent.toolCallId } }
    if !waitedOn.isEmpty { return waiting(for: waitedOn) }
    let verb = agents.allSatisfy { $0.runsInBackground || !$0.isSettled } ? "Started" : "Ran"
    return agents.count == 1 ? "\(verb) an agent" : "\(verb) \(agents.count) agents"
  }

  /// "Waiting for Map the UI", "… for Map the UI and Audit tests", or
  /// "… for 3 agents" once names would crowd the line.
  static func waiting(for agents: [ToolCall]) -> String {
    let names = agents.map(\.agentName)
    switch names.count {
    case 1: return "Waiting for \(names[0])"
    case 2: return "Waiting for \(names[0]) and \(names[1])"
    default: return "Waiting for \(names.count) agents"
    }
  }
}

extension ToolCall {
  /// Claude's Agent tool sent to the background: the turn never waits on it.
  var runsInBackground: Bool {
    if case .bool(true)? = rawInput?["run_in_background"] { return true }
    return false
  }
}
