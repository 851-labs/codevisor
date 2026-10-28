import CodevisorCore
import Foundation

struct BotSidebarRowActions {
  let select: (Bot) -> Void
  let edit: (Bot) -> Void
  let delete: (Bot) -> Void
  let moveBot: (_ botID: UUID, _ sectionID: UUID?) -> Void
  let newSection: (_ moving: Bot?) -> Void
  let toggleSection: (UUID) -> Void
  let renameSection: (BotSection) -> Void
  let deleteSection: (BotSection) -> Void
  let moveSection: (_ sectionID: UUID, _ index: Int) -> Void
}
