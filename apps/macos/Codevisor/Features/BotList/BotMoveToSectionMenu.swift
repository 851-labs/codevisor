import CodevisorCore
import SwiftUI

struct BotMoveToSectionMenu: View {
  let bot: Bot
  let currentSectionID: UUID?
  let sections: [BotSection]
  let actions: BotSidebarRowActions

  var body: some View {
    Menu("Move to Section", systemImage: "folder") {
      Picker("Move to Section", selection: section) {
        Text("No Section").tag(UUID?.none)
        if !sections.isEmpty {
          Divider()
          ForEach(sections) { section in
            Text(section.name).tag(Optional(section.id))
          }
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
      Divider()
      Button("New Section…") { actions.newSection(bot) }
    }
  }

  private var section: Binding<UUID?> {
    Binding(get: { currentSectionID }, set: { actions.moveBot(bot.id, $0) })
  }
}
