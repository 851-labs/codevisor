import ACPKit
import SwiftUI
import TranscriptKit

struct WorkedTimelineRail<Node: View, Line: View, Expanded: View>: View {
  let isFirst: Bool
  let isLast: Bool
  var onHeaderHover: ((Bool) -> Void)? = nil
  var onHeaderTap: (() -> Void)? = nil
  @ViewBuilder let node: () -> Node
  @ViewBuilder let line: () -> Line
  @ViewBuilder let expanded: () -> Expanded

  private let lineHeight: CGFloat = 18
  private let nodeWidth: CGFloat = 18
  private let verticalPadding = TranscriptTimelineMarks.linePadding
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
  @Entry var toolRowsHighlightOnHover = false
}

enum WorkedTimelineText {
  static func title(calls: [ToolCall], agents: [ToolCall], awaited: [ToolCall]) -> String {
    guard calls.isEmpty else { return ToolCallSummary.describe(calls) }
    let waitedOn = agents.filter { agent in awaited.contains { $0.toolCallId == agent.toolCallId } }
    if !waitedOn.isEmpty { return waiting(for: waitedOn) }
    let verb = agents.allSatisfy { $0.runsInBackground || !$0.isSettled } ? "Started" : "Ran"
    return agents.count == 1 ? "\(verb) an agent" : "\(verb) \(agents.count) agents"
  }

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
  var runsInBackground: Bool {
    if case .bool(true)? = rawInput?["run_in_background"] { return true }
    return false
  }
}
