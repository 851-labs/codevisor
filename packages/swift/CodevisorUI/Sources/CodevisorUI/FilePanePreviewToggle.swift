import SwiftUI

public struct FilePanePreviewToggle: View {
  private let model: FilePaneModel

  public init(model: FilePaneModel) {
    self.model = model
  }

  public static func isShown(for model: FilePaneModel) -> Bool {
    !model.isBrowsing && model.document.hasPreview
  }

  public var body: some View {
    if Self.isShown(for: model) {
      Button {
        model.editor.preview.toggle()
      } label: {
        Label(model.editor.preview ? "Edit" : "Preview", systemImage: model.editor.preview ? "pencil" : "eye")
      }
      .accessibilityLabel(helpText)
      .help(helpText)
    }
  }

  private var helpText: String {
    model.editor.preview ? "Show Editor" : "Show Preview"
  }
}
