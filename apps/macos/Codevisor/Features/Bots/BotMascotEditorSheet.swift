import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotMascotEditorSheet: View {
  private static let size = CGSize(width: 680, height: 560)
  private static let sidebarWidth: CGFloat = 190
  private static let previewSide: CGFloat = 180
  private static let swatchSide: CGFloat = 24
  private static let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

  let options: ServerBotMascotOptions
  let serverId: String
  let onSave: (ServerBotMascot) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var mascot: ServerBotMascot
  @State private var category = BotMascotCategory.color

  init(
    mascot: ServerBotMascot,
    options: ServerBotMascotOptions,
    serverId: String,
    onSave: @escaping (ServerBotMascot) -> Void
  ) {
    self.options = options
    self.serverId = serverId
    self.onSave = onSave
    _mascot = State(initialValue: mascot)
  }

  var body: some View {
    HStack(spacing: 0) {
      BotMascotCategoryList(selection: $category)
        .frame(width: Self.sidebarWidth)
      Divider()
      VStack(spacing: 0) {
        BotMascotImage(mascot: mascot, serverId: serverId)
          .frame(width: Self.previewSide, height: Self.previewSide)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 20)
        Divider()
        ScrollView {
          controls.padding(20)
        }
        buttons
      }
    }
    .frame(width: Self.size.width, height: Self.size.height)
  }

  private var controls: some View {
    BotMascotCategoryControls(
      category: category,
      options: options,
      serverId: serverId,
      columns: Self.columns,
      swatchSide: Self.swatchSide,
      mascot: $mascot
    )
  }

  private var buttons: some View {
    HStack {
      Spacer()
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Done", action: save)
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
    }
    .controlSize(.large)
    .padding(16)
    .background(.bar)
  }

  private func save() {
    onSave(mascot)
    dismiss()
  }
}
