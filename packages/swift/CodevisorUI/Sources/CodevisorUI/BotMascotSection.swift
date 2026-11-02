import CodevisorCore
import SwiftUI

public struct BotMascotSection: View {
  private static let previewSide: CGFloat = 112

  @Bindable var editor: BotEditorModel
  let showsPreview: Bool

  public init(editor: BotEditorModel, showsPreview: Bool = true) {
    self.editor = editor
    self.showsPreview = showsPreview
  }

  public var body: some View {
    if let mascot = editor.mascot, let options = editor.mascotOptions {
      Section("Mascot") {
        if showsPreview {
          BotMascotImage(mascot: mascot, serverId: editor.serverId)
            .frame(width: Self.previewSide, height: Self.previewSide)
            .frame(maxWidth: .infinity)
        }
        BotMascotColorPicker(colors: options.colors, selection: choice(\.color))
        Picker("Hat", selection: choice(\.hat)) {
          ForEach(options.hats) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.menu)
        Picker("Eyewear", selection: choice(\.eyewear)) {
          ForEach(options.eyewear) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.menu)
      }
    }
  }

  private func choice(_ part: WritableKeyPath<ServerBotMascot, String>) -> Binding<String> {
    Binding(
      get: { editor.mascot?[keyPath: part] ?? "" },
      set: { editor.mascot?[keyPath: part] = $0 }
    )
  }
}
