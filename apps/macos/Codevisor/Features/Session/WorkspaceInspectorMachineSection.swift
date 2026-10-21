import CodevisorClient
import SwiftUI

struct WorkspaceInspectorMachineSection: View {
  static let refreshInterval: Duration = .seconds(3)
  static let historySlots = 100

  let stats: ServerMachineStats
  @Binding var isExpanded: Bool

  var body: some View {
    WorkspaceInspectorCard(title: "Machine", isExpanded: $isExpanded) {
      WorkspaceInspectorMachineLoad(
        title: "CPU", usedPercent: stats.cpu.usedPercent, history: stats.cpu.history,
        detail: "\(stats.cpu.cores) cores")
      if let gpu = stats.gpu {
        WorkspaceInspectorMachineLoad(
          title: "GPU", usedPercent: gpu.usedPercent, history: gpu.history,
          detail: [gpu.model, gpu.cores.map { "\($0) cores" }].compactMap { $0 }.joined(separator: " · "))
      }
      WorkspaceInspectorMachineUsageRow(title: "Memory", usage: stats.memory, style: .memory)
      if let disk = stats.disk {
        WorkspaceInspectorMachineUsageRow(title: "Disk", usage: disk, style: .file)
      }
      LabeledContent("Uptime", value: Self.uptimeText(stats.uptimeSeconds))
    }
  }

  static func uptimeText(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
  }

  static func tint(forPercent percent: Double) -> Color {
    switch percent {
    case 90...: .red
    case 75...: .orange
    default: .accentColor
    }
  }
}

private struct WorkspaceInspectorMachineLoad: View {
  let title: String
  let usedPercent: Double?
  let history: [ServerMachineStats.LoadSample]
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
        Spacer()
        Group {
          if let usedPercent {
            Text(usedPercent / 100, format: .percent.precision(.fractionLength(0)))
          } else {
            Text("Measuring…")
          }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
      }
      WorkspaceInspectorSparkline(
        values: history.map(\.usedPercent),
        slots: WorkspaceInspectorMachineSection.historySlots,
        tint: WorkspaceInspectorMachineSection.tint(forPercent: usedPercent ?? 0)
      )
      .frame(height: 28)
      Text(
        [detail.isEmpty ? nil : detail, Self.windowText(history).map { "last \($0)" }].compactMap { $0 }
          .joined(separator: " · ")
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(usedPercent.map { "\(Int($0.rounded())) percent" } ?? "Measuring")
  }

  private static func windowText(_ history: [ServerMachineStats.LoadSample]) -> String? {
    guard let first = history.first.flatMap({ try? ServerDateCoding.date(from: $0.at) }),
      let last = history.last.flatMap({ try? ServerDateCoding.date(from: $0.at) }),
      last > first
    else { return nil }
    let seconds = last.timeIntervalSince(first)
    return seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
  }
}

private struct WorkspaceInspectorMachineUsageRow: View {
  let title: String
  let usage: ServerMachineStats.Usage
  let style: ByteCountFormatStyle.Style

  private var percent: Double {
    usage.totalBytes > 0 ? usage.usedBytes / usage.totalBytes * 100 : 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
        Spacer()
        Text("\(bytes(usage.usedBytes)) of \(bytes(usage.totalBytes))")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      WorkspaceInspectorMeter(
        segments: [.init(color: WorkspaceInspectorMachineSection.tint(forPercent: percent), value: usage.usedBytes)],
        total: usage.totalBytes
      )
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  private func bytes(_ value: Double) -> String {
    Int64(value).formatted(.byteCount(style: style))
  }
}

private struct WorkspaceInspectorSparkline: View {
  let values: [Double]
  let slots: Int
  let tint: Color

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let step = size.width / CGFloat(max(slots - 1, 1))
      let points = values.suffix(slots).enumerated().map { index, value in
        CGPoint(
          x: size.width - CGFloat(min(values.count, slots) - 1 - index) * step,
          y: size.height * (1 - CGFloat(min(max(value, 0), 100)) / 100))
      }
      ZStack {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(.quaternary.opacity(0.5))
        if points.count > 1 {
          Path { path in
            path.move(to: CGPoint(x: points[0].x, y: size.height))
            points.forEach { path.addLine(to: $0) }
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            path.closeSubpath()
          }
          .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.05)], startPoint: .top, endPoint: .bottom))
          Path { path in
            path.addLines(points)
          }
          .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
    .accessibilityHidden(true)
  }
}
