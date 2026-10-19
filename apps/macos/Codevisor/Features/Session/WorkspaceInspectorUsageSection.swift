import CodevisorClient
import SwiftUI

struct WorkspaceInspectorUsageSection: View {
  let limits: ServerHarnessUsageLimits
  @Binding var isExpanded: Bool

  var body: some View {
    Section("Usage", isExpanded: $isExpanded) {
      if let account = limits.accountEmail ?? limits.accountLabel {
        HStack(spacing: 12) {
          Text("Account")
            .layoutPriority(1)
          Spacer(minLength: 0)
          Text(account)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      ForEach(limits.windows) { window in
        WorkspaceInspectorUsageWindowRow(window: window)
      }
      if let credits = limits.credits, credits.hasCredits || credits.unlimited {
        LabeledContent("Credits", value: credits.unlimited ? "Unlimited" : Self.balanceText(credits.balance))
      }
    }
  }

  static func balanceText(_ balance: String?) -> String {
    guard let balance else { return "Available" }
    guard let amount = Double(balance) else { return balance }
    return amount.formatted(.number.precision(.fractionLength(0...2)))
  }
}

private struct WorkspaceInspectorUsageWindowRow: View {
  let window: ServerHarnessUsageWindow

  private var used: Double { min(max(window.usedPercent, 0), 100) }

  private var tint: Color {
    switch used {
    case 90...: .red
    case 75...: .orange
    default: .accentColor
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(window.label)
        Spacer()
        Text(used / 100, format: .percent.precision(.fractionLength(0)))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      ProgressView(value: used, total: 100)
        .progressViewStyle(.linear)
        .tint(tint)
        .labelsHidden()
      if let resetsAt = window.resetsAt.flatMap({ try? ServerDateCoding.date(from: $0) }) {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(Self.resetText(resetsAt, now: context.date))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  static func resetText(_ date: Date, now: Date) -> String {
    guard date > now else { return "Resets soon" }
    if date.timeIntervalSince(now) < 86_400 {
      return "Resets \(date.formatted(.relative(presentation: .named)))"
    }
    return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
  }
}
