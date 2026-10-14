import SwiftUI

public struct TranscriptDisclosureContentReveal<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  let isExpanded: Bool
  @State private var isVisible: Bool
  private let content: Content

  public init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
    self.isExpanded = isExpanded
    _isVisible = State(initialValue: isExpanded)
    self.content = content()
  }

  public var body: some View {
    Group {
      if isExpanded {
        content
          .opacity(isVisible || reduceMotion ? 1 : 0)
          .offset(y: isVisible || reduceMotion ? 0 : -8)
          .onAppear {
            revealIfNeeded()
          }
      }
    }
    .onChange(of: isExpanded) { _, expanded in
      if !expanded {
        isVisible = false
      }
      invalidateRowMeasurement?()
    }
  }

  private func revealIfNeeded() {
    guard !isVisible else { return }
    guard !reduceMotion else {
      isVisible = true
      return
    }
    withAnimation(Motion.entrance()) {
      isVisible = true
    }
  }
}
