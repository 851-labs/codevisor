import SwiftUI

/// How long an attachment must be loading before its spinner appears. A
/// cached or nearby file opens before then and never flashes one.
private let attachmentLoadingDelay: Duration = .milliseconds(150)

/// Dims an attachment thumbnail and shows a spinner while its full file
/// downloads for Quick Look. The spinner badge matches `VideoPlayBadge`'s
/// footprint, so it covers a video's play glyph instead of stacking on it.
public struct AttachmentLoadingOverlay: View {
  private let isLoading: Bool

  public init(isLoading: Bool) {
    self.isLoading = isLoading
  }

  public var body: some View {
    DelayedActivity(isActive: isLoading) { isVisible in
      if isVisible {
        ZStack {
          Rectangle().fill(.black.opacity(0.25))
          ProgressView()
            .controlSize(.small)
            .tint(.white)
            .environment(\.colorScheme, .dark)
            .frame(width: 28, height: 28)
            .background(Circle().fill(.black.opacity(0.6)))
        }
        .transition(.opacity)
      }
    }
    .allowsHitTesting(false)
  }
}

/// The leading glyph of a file chip: its document icon, swapped for a
/// spinner while the file downloads for Quick Look.
public struct AttachmentChipIcon: View {
  private let isLoading: Bool

  public init(isLoading: Bool) {
    self.isLoading = isLoading
  }

  public var body: some View {
    DelayedActivity(isActive: isLoading) { isVisible in
      if isVisible {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "doc")
          .foregroundStyle(.secondary)
      }
    }
    // One footprint for both glyphs so the filename doesn't shift.
    .frame(width: 18, height: 18)
  }
}

/// Reports `isActive` to `content` only once it has held for
/// `attachmentLoadingDelay`, and clears it immediately when it ends.
private struct DelayedActivity<Content: View>: View {
  let isActive: Bool
  @ViewBuilder let content: (Bool) -> Content
  @State private var isVisible = false

  var body: some View {
    content(isVisible)
      .animation(.easeOut(duration: 0.15), value: isVisible)
      .task(id: isActive) {
        guard isActive else {
          isVisible = false
          return
        }
        try? await Task.sleep(for: attachmentLoadingDelay)
        guard !Task.isCancelled else { return }
        isVisible = true
      }
  }
}
