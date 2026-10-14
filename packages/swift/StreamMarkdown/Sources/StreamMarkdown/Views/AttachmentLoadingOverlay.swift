import SwiftUI

private let attachmentLoadingDelay: Duration = .milliseconds(150)

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
    .frame(width: 18, height: 18)
  }
}

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
