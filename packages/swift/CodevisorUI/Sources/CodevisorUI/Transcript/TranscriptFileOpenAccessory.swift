import SwiftUI
import TranscriptKit

struct TranscriptFileOpenAccessory: View {
  let file: PreviewFile

  var body: some View {
    TranscriptFileOpenButton(file: file) {
      Label {
        Text("Open")
      } icon: {
        Image(systemName: "arrow.up.forward.square")
          .frame(width: 13, height: 13)
      }
      .font(.caption2)
      .labelStyle(.titleAndIcon)
      .foregroundStyle(.secondary)
    }
    .accessibilityLabel("Open \(file.name)")
  }
}
