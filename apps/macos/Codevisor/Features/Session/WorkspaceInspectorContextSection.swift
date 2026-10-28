import ACPKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorContextSection: View {
  struct LoadKey: Equatable {
    let sessionId: UUID
    let usage: SessionUsage?
    let activity: Date?
  }

  let context: ServerSessionContext?
  let usage: SessionUsage?
  @Binding var isExpanded: Bool

  var body: some View {
    if let totals {
      WorkspaceInspectorCard(title: "Context", isExpanded: $isExpanded) {
        WorkspaceInspectorContextOverview(
          used: totals.used,
          size: totals.size,
          segments: context.map { active(in: $0).filter { !$0.isFreeSpace }.map(\.segment) } ?? []
        )
        if let context {
          ForEach(active(in: context) + context.categories.filter { $0.isDeferred == true }, id: \.name) {
            category in
            WorkspaceInspectorContextRow(category: category, maxTokens: context.maxTokens)
          }
        }
      }
    }
  }

  private var totals: (used: Double, size: Double)? {
    if let context { return (context.totalTokens, context.maxTokens) }
    guard let used = usage?.used, let size = usage?.size, size > 0 else { return nil }
    return (Double(used), Double(size))
  }

  private func active(in context: ServerSessionContext) -> [ServerSessionContext.Category] {
    context.categories
      .filter { $0.isDeferred != true }
      .sorted { ($0.rank, -$0.tokens) < ($1.rank, -$1.tokens) }
  }
}

private struct WorkspaceInspectorContextOverview: View {
  let used: Double
  let size: Double
  let segments: [WorkspaceInspectorMeter.Segment]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      WorkspaceInspectorContextSummary(used: used, size: size)
      WorkspaceInspectorContextBar(segments: segments, used: used, size: size)
    }
    .padding(.vertical, 4)
  }
}

private struct WorkspaceInspectorContextSummary: View {
  let used: Double
  let size: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("\(Int((used / size * 100).rounded()))% used")
        .monospacedDigit()
        .contentTransition(.numericText(value: used / size))
      Spacer(minLength: 8)
      Text("\(WorkspaceInspectorContextTokens.format(used)) / \(WorkspaceInspectorContextTokens.format(size))")
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .contentTransition(.numericText(value: used))
    }
    .animation(Motion.meter(reduceMotion: reduceMotion), value: [used, size])
  }
}

private struct WorkspaceInspectorContextBar: View {
  let segments: [WorkspaceInspectorMeter.Segment]
  let used: Double
  let size: Double

  var body: some View {
    WorkspaceInspectorMeter(
      segments: segments.isEmpty ? [.init(id: "Used", color: .accentColor, value: used)] : segments,
      total: size
    )
    .accessibilityLabel("Context used")
  }
}

private struct WorkspaceInspectorContextRow: View {
  let category: ServerSessionContext.Category
  let maxTokens: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(category.tint)
        .frame(width: 10, height: 10)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      Text(category.name)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(category.isDeferred == true ? .secondary : .primary)
      Spacer(minLength: 8)
      Text(WorkspaceInspectorContextTokens.format(category.tokens))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .contentTransition(.numericText(value: category.tokens))
      Text(category.isDeferred == true ? "—" : percent)
        .foregroundStyle(category.isDeferred == true ? .secondary : .primary)
        .monospacedDigit()
        .contentTransition(.numericText(value: category.tokens / maxTokens))
        .frame(minWidth: 44, alignment: .trailing)
    }
    .animation(Motion.meter(reduceMotion: reduceMotion), value: [category.tokens, maxTokens])
    .accessibilityElement(children: .combine)
  }

  private var percent: String {
    (category.tokens / maxTokens).formatted(.percent.precision(.fractionLength(1)))
  }
}

enum WorkspaceInspectorContextTokens {
  static func format(_ tokens: Double) -> String {
    let (value, suffix) = scaled(tokens)
    return value.formatted(.number.precision(.fractionLength(0...1))) + suffix
  }

  private nonisolated static func scaled(_ tokens: Double) -> (Double, String) {
    if tokens >= 1_000_000 { return (tokens / 1_000_000, "M") }
    if tokens >= 1_000 { return (tokens / 1_000, "k") }
    return (tokens, "")
  }
}

extension ServerSessionContext.Category {
  fileprivate var isFreeSpace: Bool { name == "Free space" }

  fileprivate var segment: WorkspaceInspectorMeter.Segment {
    .init(id: name, color: tint, value: tokens)
  }

  fileprivate var rank: Int {
    switch name {
    case "Autocompact buffer": 1
    case "Free space": 2
    default: 0
    }
  }

  fileprivate var tint: Color {
    if isDeferred == true { return Color.secondary.opacity(0.35) }
    switch name {
    case "Messages", "Input": return .blue
    case "Cached input": return .teal
    case "Output": return .green
    case "Reasoning": return .indigo
    case "System tools": return .orange
    case "MCP tools": return .green
    case "System prompt": return .yellow
    case "Memory files": return .purple
    case "Custom agents": return .teal
    case "Skills", "MCP server instructions", "Slash commands": return .gray
    case "Autocompact buffer": return Color.secondary.opacity(0.35)
    case "Free space": return Color.secondary.opacity(0.15)
    default: break
    }
    switch color {
    case "claude": return .orange
    case "warning": return .yellow
    case "success": return .green
    case "permission", "suggestion": return .blue
    default: return .gray
    }
  }
}
