import SwiftUI

struct BotListScrollView<Content: View>: View {
  let selectedBotID: UUID?
  let isSelectedBotArchived: Bool
  let newSection: () -> Void
  @ViewBuilder let content: () -> Content
  @FocusState private var isFocused: Bool

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        content()
      }
      .scrollContentBackground(.hidden)
      .focusable()
      .focusEffectDisabled()
      .focused($isFocused)
      .contextMenu {
        Button(action: newSection) {
          Label("New Section…", systemImage: "folder.badge.plus")
            .labelStyle(.titleAndIcon)
        }
      }
      .onChange(of: selectedBotID) { _, id in
        if let id { proxy.scrollTo(id) }
        if isSelectedBotArchived { isFocused = true }
      }
    }
  }
}
