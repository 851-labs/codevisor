import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotMascotEditorScreen: View {
  private static let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

  let options: ServerBotMascotOptions
  let serverId: String
  let onSave: (ServerBotMascot) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var mascot: ServerBotMascot
  @State private var category: BotMascotCategory
  @ScaledMetric(relativeTo: .largeTitle) private var previewSide: CGFloat = 200
  @ScaledMetric(relativeTo: .title) private var swatchSide: CGFloat = 28

  init(
    mascot: ServerBotMascot,
    options: ServerBotMascotOptions,
    serverId: String,
    category: BotMascotCategory = .color,
    onSave: @escaping (ServerBotMascot) -> Void
  ) {
    self.options = options
    self.serverId = serverId
    self.onSave = onSave
    _mascot = State(initialValue: mascot)
    _category = State(initialValue: category)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        BotMascotImage(mascot: mascot, serverId: serverId)
          .frame(width: previewSide, height: previewSide)
          .padding(.vertical, 16)
        BotMascotCategoryTabs(selection: $category)
        Divider()
        ScrollView {
          controls.padding()
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(role: .confirm, action: save)
        }
      }
    }
  }

  private var controls: some View {
    BotMascotCategoryControls(
      category: category,
      options: options,
      serverId: serverId,
      columns: Self.columns,
      swatchSide: swatchSide,
      mascot: $mascot
    )
  }

  private func save() {
    onSave(mascot)
    dismiss()
  }
}
