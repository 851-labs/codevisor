import CodevisorCore
import SwiftUI

struct BotMoveToSectionMenu: View {
  let bot: Bot
  let currentSectionID: UUID?
  let sections: [BotSection]
  let actions: BotSidebarRowActions

  var body: some View {
    Menu("Move to Section", systemImage: "folder") {
      Button("No Section") { actions.moveBot(bot.id, nil) }
        .disabled(currentSectionID == nil)
      if !sections.isEmpty {
        Divider()
        ForEach(sections) { section in
          Button(section.name) { actions.moveBot(bot.id, section.id) }
            .disabled(section.id == currentSectionID)
        }
      }
      Divider()
      Button("New Section…") { actions.newSection(bot) }
    }
  }
}
