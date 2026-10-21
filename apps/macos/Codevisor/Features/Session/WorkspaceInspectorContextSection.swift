import ACPKit
import CodevisorClient
import CodevisorCore
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
    if let context {
      Section("Context", isExpanded: $isExpanded) {
        WorkspaceInspectorContextOverview(
          used: context.totalTokens,
          size: context.maxTokens,
          segments: active(in: context).filter { !$0.isFreeSpace }.map { ($0.tint, $0.tokens) }
        )
        ForEach(active(in: context) + context.categories.filter { $0.isDeferred == true }, id: \.name) {
          category in
          WorkspaceInspectorContextRow(category: category, maxTokens: context.maxTokens)
        }
      }
    } else if let used = usage?.used, let size = usage?.size, size > 0 {
      Section("Context", isExpanded: $isExpanded) {
        WorkspaceInspectorContextOverview(used: Double(used), size: Double(size), segments: [])
      }
    }
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
  let segments: [(Color, Double)]

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

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("\(Int((used / size * 100).rounded()))% used")
      Spacer(minLength: 8)
      Text("\(WorkspaceInspectorContextTokens.format(used)) / \(WorkspaceInspectorContextTokens.format(size))")
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

private struct WorkspaceInspectorContextBar: View {
  let segments: [(Color, Double)]
  let used: Double
  let size: Double

  var body: some View {
    WorkspaceInspectorMeter(
      segments: segments.isEmpty
        ? [.init(color: .accentColor, value: used)] : segments.map { .init(color: $0.0, value: $0.1) },
      total: size
    )
    .accessibilityLabel("Context used")
  }
}

private struct WorkspaceInspectorContextRow: View {
  let category: ServerSessionContext.Category
  let maxTokens: Double

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
      Text(category.isDeferred == true ? "—" : percent)
        .foregroundStyle(category.isDeferred == true ? .secondary : .primary)
        .monospacedDigit()
        .frame(minWidth: 44, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
  }

  private var percent: String {
    (category.tokens / maxTokens).formatted(.percent.precision(.fractionLength(1)))
  }
}

enum WorkspaceInspectorContextTokens {
  static func format(_ tokens: Double) -> String {
    let (value, suffix): (Double, String) =
      tokens >= 1_000_000 ? (tokens / 1_000_000, "M") : tokens >= 1_000 ? (tokens / 1_000, "k") : (tokens, "")
    return value.formatted(.number.precision(.fractionLength(0...1))) + suffix
  }
}

extension ServerSessionContext.Category {
  fileprivate var isFreeSpace: Bool { name == "Free space" }

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
