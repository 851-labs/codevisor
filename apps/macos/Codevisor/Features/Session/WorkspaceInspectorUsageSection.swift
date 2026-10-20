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
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let pace = window.pace(now: context.date)
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
          .overlay(alignment: .leading) {
            if let pace {
              WorkspaceInspectorUsagePaceMarker(pace: pace)
            }
          }
        if let caption = Self.caption(pace: pace, resetsAt: resetsAt, now: context.date) {
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  private var resetsAt: Date? {
    window.resetsAt.flatMap { try? ServerDateCoding.date(from: $0) }
  }

  static func caption(pace: ServerHarnessUsagePace?, resetsAt: Date?, now: Date) -> String? {
    var parts: [String] = []
    if let pace {
      let reserve = Int(pace.reservePercent.rounded())
      parts.append(
        reserve == 0 ? "On pace" : reserve > 0 ? "\(reserve)% in reserve" : "\(-reserve)% in deficit")
      switch pace.outlook {
      case .lastsUntilReset:
        parts.append("Lasts until reset")
      case let .runsOut(date):
        parts.append(date > now ? "Runs out \(moment(date, now: now))" : "Runs out now")
      }
    }
    if let resetsAt {
      parts.append(resetsAt > now ? "Resets \(moment(resetsAt, now: now))" : "Resets soon")
    }
    return parts.isEmpty
      ? nil : parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
  }

  private static func moment(_ date: Date, now: Date) -> String {
    date.timeIntervalSince(now) < 86_400
      ? date.formatted(.relative(presentation: .named))
      : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }
}

private struct WorkspaceInspectorUsagePaceMarker: View {
  let pace: ServerHarnessUsagePace

  var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(pace.reservePercent >= 0 ? Color.green : Color.red)
        .frame(width: 2, height: 12)
        .padding(.horizontal, 1)
        .background(Capsule().fill(.white.opacity(0.85)))
        .position(
          x: min(max(proxy.size.width * pace.expectedPercent / 100, 2), proxy.size.width - 2),
          y: proxy.size.height / 2)
    }
    .accessibilityHidden(true)
  }
}
