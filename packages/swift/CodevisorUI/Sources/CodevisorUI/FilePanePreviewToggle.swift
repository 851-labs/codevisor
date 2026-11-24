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
        Label(model.editor.preview ? sourceTitle : "Preview", systemImage: model.editor.preview ? sourceImage : "eye")
      }
      .accessibilityLabel(helpText)
      .help(helpText)
    }
  }

  private var isViewing: Bool { model.access == .viewing }

  private var sourceTitle: String { isViewing ? "Source" : "Edit" }

  private var sourceImage: String { isViewing ? "chevron.left.forwardslash.chevron.right" : "pencil" }

  private var helpText: String {
    if model.editor.preview { return isViewing ? "Show Source" : "Show Editor" }
    return "Show Preview"
  }
}
