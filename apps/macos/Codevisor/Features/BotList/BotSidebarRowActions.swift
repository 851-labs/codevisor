import CodevisorCore
import Foundation

struct BotSidebarRowActions {
  let select: (Bot) -> Void
  let edit: (Bot) -> Void
  let canArchive: (Bot) -> Bool
  let archive: (Bot) -> Void
  let unarchive: (Bot) -> Void
  let delete: (Bot) -> Void
  let moveBot: (_ botID: UUID, _ sectionID: UUID?) -> Void
  let newSection: (_ moving: Bot?) -> Void
  let toggleSection: (UUID) -> Void
  let toggleArchived: () -> Void
  let renameSection: (CustomSection) -> Void
  let deleteSection: (CustomSection) -> Void
  let moveSection: (_ sectionID: UUID, _ index: Int) -> Void
}
