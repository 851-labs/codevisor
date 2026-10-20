import SwiftUI
import TranscriptKit

struct TranscriptFileOpenButton<Label: View>: View {
  @Environment(\.openFileDocument) private var openFileDocument
  @Environment(\.quickLook) private var quickLook
  @Environment(\.attachmentImages) private var attachmentImages
  let file: PreviewFile
  @ViewBuilder let label: Label

  var body: some View {
    Button(action: open) { label }
      .buttonStyle(.plain)
      .help("Open \(file.name)")
  }

  private func open() {
    if openFileDocument?(FileDocumentLocation.target(for: file)) == true { return }
    quickLook?.present(QuickLookItem(file), attachmentStore: attachmentImages)
  }
}
