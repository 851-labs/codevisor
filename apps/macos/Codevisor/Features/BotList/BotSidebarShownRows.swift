import CodevisorUI

final class BotSidebarShownRows {
  private(set) var rows: [BotSidebarRow]?

  func show(_ rows: [BotSidebarRow]?) -> [BotSidebarRow]? {
    self.rows = rows
    return rows
  }
}
