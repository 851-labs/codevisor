import SwiftUI

struct FloatingPaneTrailingToolbar<Content: View>: View {
  @ViewBuilder let content: () -> Content

  @State private var showingOverflow = false

  var body: some View {
    ViewThatFits(in: .horizontal) {
      controls.fixedSize()
      overflowButton
    }
  }

  private var controls: some View {
    FloatingPaneGlassGroup { content() }
  }

  private var overflowButton: some View {
    FloatingPaneGlassGroup {
      Button {
        showingOverflow.toggle()
      } label: {
        Image(systemName: "chevron.right.2")
          .font(.system(size: 11, weight: .semibold))
      }
      .help("More Controls")
      .accessibilityLabel("More Controls")
    }
    .popover(isPresented: $showingOverflow, arrowEdge: .bottom) {
      GlassEffectContainer { controls }
        .padding(8)
    }
  }
}
