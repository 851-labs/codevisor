import CodevisorUI
import SwiftUI

/// Shared chrome for every question card presentation, so the generic picker
/// and first-party flows read as one family inside the composer's glass.
/// The question itself is the header — no separate caption row above it.
///
/// The card itself is the one Liquid Glass surface; everything here is
/// content on that glass — plain fills and tints, never nested glass.
struct QuestionCardHeader: View {
  let title: String
  /// Clamps a long question while space is tight (the keyboard is up).
  var lineLimit: Int?
  let dismissLabel: String
  let onDismiss: () -> Void

  var body: some View {
    // Top-aligned so a multi-line question grows downward; the text's
    // first line is padded to sit centered on the 30pt close button.
    HStack(alignment: .top, spacing: 10) {
      Text(title)
        .font(.headline)
        .lineLimit(lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentTransition(.opacity)
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .composerCircleActionLabel(.secondary)
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .accessibilityLabel(dismissLabel)
    }
  }
}
