import ACPKit
import StreamMarkdown
import SwiftUI
import TranscriptKit

/// The expanded body of a gateway workflow: the code it ran, highlighted the
/// same way code blocks in messages are. Its label already says what it did
/// and whether it failed.
struct CodevisorWorkflowDetailView: View {
  let details: CodevisorWorkflowDetails

  var body: some View {
    if let code = details.code, !code.isEmpty {
      StreamingMarkdownView(Self.fenced(code))
    } else if let text = details.failure ?? details.result {
      // A harness that didn't report the code: show what we have.
      ExpandableText(text: text, noun: "output")
    }
  }

  /// A fenced block whose fence can't be closed early by backticks inside
  /// the code itself.
  static func fenced(_ code: String) -> String {
    var fence = "```"
    while code.contains(fence) { fence += "`" }
    return "\(fence)typescript\n\(code)\n\(fence)"
  }
}

/// Monospaced text that shows its first lines and lets the reader open the
/// rest, so a large result doesn't swallow the transcript.
private struct ExpandableText: View {
  let text: String
  let noun: String
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @State private var showsAll = false

  private static let previewLines = 12

  var body: some View {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let isLong = lines.count > Self.previewLines
    VStack(alignment: .leading, spacing: 6) {
      ToolCallMonospacedText(
        text: isLong && !showsAll ? lines.prefix(Self.previewLines).joined(separator: "\n") + "\n…" : text
      )
      if isLong {
        Button(showsAll ? "Show less" : "Show full \(noun) (\(lines.count) lines)") {
          showsAll.toggle()
          invalidateRowMeasurement?()
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      }
    }
  }
}
