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
    HStack(spacing: 4) { content() }
  }

  private var overflowButton: some View {
    Button {
      showingOverflow.toggle()
    } label: {
      Image(systemName: "chevron.right.2")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("More Controls")
    .accessibilityLabel("More Controls")
    .popover(isPresented: $showingOverflow, arrowEdge: .bottom) {
      controls.padding(8)
    }
  }
}
