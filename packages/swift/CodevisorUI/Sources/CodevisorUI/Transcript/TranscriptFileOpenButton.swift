import SwiftUI
import TranscriptKit

struct TranscriptFileOpenButton<Label: View>: View {
  @Environment(\.fileOpener) private var fileOpener
  let file: PreviewFile
  @ViewBuilder let label: Label

  var body: some View {
    Button(action: open) { label }
      .buttonStyle(.plain)
      .help("Open \(file.name)")
  }

  private func open() {
    fileOpener?.open(ViewableFile(file))
  }
}
