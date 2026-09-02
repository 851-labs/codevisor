import CodevisorUI
import SwiftUI

/// Reveals the next page of archived chats.
///
/// The rows themselves are already in memory, so the spinner is not hiding
/// a fetch — it acknowledges the click and covers the layout pass for the
/// added rows, which is the part that can actually stutter on a large
/// archive. Keeping it on screen for a beat also stops a rapid double
/// click from jumping two pages before the first has drawn.
struct SidebarShowMoreArchivedRow: View {
  let remaining: Int
  let pageSize: Int
  let titleFont: Font
  @Binding var archivedVisibleCount: Int
  @Binding var isLoadingMoreArchived: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 6) {
      if isLoadingMoreArchived {
        ProgressView()
          .controlSize(.small)
          .frame(width: 18)
      } else {
        Image(systemName: "ellipsis.circle")
          .frame(width: 18)
          .foregroundStyle(.secondary)
      }
      Text(isLoadingMoreArchived ? "Loading…" : "Show \(min(remaining, pageSize)) more")
        .font(titleFont)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .sidebarRowHover(isEnabled: !isLoadingMoreArchived)
    .onTapGesture {
      guard !isLoadingMoreArchived else { return }
      isLoadingMoreArchived = true
      Task {
        // One runloop hop so the spinner actually renders before the
        // rows are added and SwiftUI re-lays out the list.
        try? await Task.sleep(for: .milliseconds(180))
        withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
          archivedVisibleCount += pageSize
        }
        isLoadingMoreArchived = false
      }
    }
    .accessibilityLabel("Show more archived chats")
    .accessibilityAddTraits(.isButton)
  }
}
