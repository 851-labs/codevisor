import CodevisorCore
import SwiftUI

struct TranscriptEventPopoverButton<Label: View>: View {
  let marker: TranscriptEventMarker
  @ViewBuilder let label: (_ isPresented: Bool) -> Label
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented = true
    } label: {
      label(isPresented)
    }
    .buttonStyle(.plain)
    .accessibilityHint("Shows the message")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      TranscriptEventPopover(marker: marker)
    }
  }
}
