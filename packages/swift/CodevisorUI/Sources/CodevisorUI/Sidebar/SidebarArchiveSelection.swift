public enum SidebarArchiveSelection<ID: Hashable>: Equatable {
  case unchanged
  case select(ID)
  case clear

  public static func after(
    archiving archived: ID, selected: ID?, sections: [[ID]], leaving: Set<ID> = []
  ) -> Self {
    guard selected == archived else { return .unchanged }
    let next = rowsLikeChromeTabs(closing: archived, in: sections).first {
      $0 != archived && !leaving.contains($0)
    }
    return next.map(Self.select) ?? .clear
  }

  private static func rowsLikeChromeTabs(closing archived: ID, in sections: [[ID]]) -> [ID] {
    guard let index = sections.firstIndex(where: { $0.contains(archived) }),
      let position = sections[index].firstIndex(of: archived)
    else { return Array(sections.joined()) }
    let section = sections[index]
    let below = section[(position + 1)...]
    let above = section[..<position].reversed()
    let sectionsBelow = sections[(index + 1)...].joined()
    let sectionsAbove = sections[..<index].reversed().flatMap { $0.reversed() }
    return Array(below) + above + sectionsBelow + sectionsAbove
  }
}
