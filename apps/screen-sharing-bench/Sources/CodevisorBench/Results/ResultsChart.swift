import Foundation
import ScreenSharingBench

struct ResultsChart {
  struct Row {
    let label: String
    let e2eP50Ms: Double?
    let stages: BenchStageMedians
    let history: [Double]
  }

  private static let width = 960.0
  private static let rowHeight = 24.0
  private static let top = 64.0
  private static let labelWidth = 170.0
  private static let barWidth = 520.0
  private static let sparkX = 770.0
  private static let sparkWidth = 170.0
  private static let longestBarMs = 250.0
  private static let segmentGap = 2.0
  private static let smallestTrendSpan = 0.2
  private static let colorSlots = [
    "capture": 0, "capture queue": 1, "encode": 2, "network": 3, "send": 3, "jitter buffer": 4, "decode": 5,
    "render queue": 6, "present": 7,
  ]

  let title: String
  let rows: [Row]

  var svg: String {
    let height = Self.top + Double(rows.count) * Self.rowHeight + 12
    let body = [header] + rows.enumerated().map { row($1, y: Self.top + Double($0) * Self.rowHeight) }
    return """
      <svg xmlns="http://www.w3.org/2000/svg" width="\(Self.width)" height="\(height)" \
      viewBox="0 0 \(Self.width) \(height)" font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="12">
      <style>\(ResultsChartPalette.style)</style>
      <rect class="surface" width="100%" height="100%" rx="6"/>
      \(body.joined(separator: "\n"))
      </svg>

      """
  }

  private var scaleMs: Double {
    min(Self.longestBarMs, rows.compactMap(\.e2eP50Ms).max() ?? 1)
  }

  private var isSplit: Bool {
    rows.contains { $0.stages.isSplitAtTheJitterBuffer }
  }

  private var header: String {
    let legend = BenchStageMedians().ordered(splitAtTheJitterBuffer: isSplit).enumerated().map { index, stage in
      let x = 8 + Double(index) * 118
      return
        "<rect class=\"s\(Self.colorSlots[stage.name] ?? 0)\" x=\"\(x)\" y=\"12\" width=\"10\" height=\"10\" rx=\"2\"/>"
        + "<text class=\"ink\" x=\"\(x + 14)\" y=\"21\">\(stage.name)</text>"
    }
    return legend.joined() + """
      <text class="muted" x="8" y="48">\(Self.escaped(title))</text>
      <text class="muted" x="\(Self.labelWidth)" y="48">e2e p50 by stage, ms (bars stop at \(Int(scaleMs)) ms)</text>
      <text class="muted" x="\(Self.sparkX)" y="48">e2e p50 nightly trend</text>
      """
  }

  private func row(_ row: Row, y: Double) -> String {
    let label = "<text class=\"ink\" x=\"8\" y=\"\(y + 16)\">\(Self.escaped(row.label))</text>"
    return label + bar(row, y: y) + sparkline(row.history, y: y)
  }

  private func bar(_ row: Row, y: Double) -> String {
    var x = Self.labelWidth
    var segments: [String] = []
    for stage in row.stages.ordered(splitAtTheJitterBuffer: isSplit) {
      guard let ms = stage.p50Ms, ms > 0, x < Self.labelWidth + Self.barWidth else { continue }

      let length = min(ms / scaleMs * Self.barWidth, Self.labelWidth + Self.barWidth - x)
      segments.append(
        "<rect class=\"s\(Self.colorSlots[stage.name] ?? 0)\" x=\"\(Self.rounded(x))\" y=\"\(y + 5)\" "
          + "width=\"\(Self.rounded(max(length - Self.segmentGap, 1)))\" height=\"14\" rx=\"2\"/>")
      x += length
    }
    let total = row.e2eP50Ms.map { String(format: "%.1f ms", $0) } ?? "no frames"
    let text = "<text class=\"ink\" x=\"\(Self.rounded(x + 6))\" y=\"\(y + 16)\">\(total)</text>"
    return segments.joined() + text
  }

  private func sparkline(_ values: [Double], y: Double) -> String {
    guard let low = values.min(), let high = values.max(), values.count > 1 else { return "" }

    let span = max(high - low, Self.smallestTrendSpan * high, 0.001)
    let floor = (low + high - span) / 2
    let step = Self.sparkWidth / Double(values.count - 1)
    let points = values.enumerated().map { index, value in
      (Self.sparkX + Double(index) * step, y + 20 - (value - floor) / span * 16)
    }
    let path = points.map { "\(Self.rounded($0.0)),\(Self.rounded($0.1))" }.joined(separator: " ")
    let last = points[points.count - 1]
    return "<polyline class=\"line\" points=\"\(path)\"/>"
      + "<circle class=\"dot\" cx=\"\(Self.rounded(last.0))\" cy=\"\(Self.rounded(last.1))\" r=\"3\"/>"
  }

  private static func rounded(_ value: Double) -> String {
    String(format: "%.1f", value)
  }

  private static func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
