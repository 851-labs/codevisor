struct CommandPaletteSection: Identifiable {
  let id: String
  let title: String
  let items: [CommandPaletteItem]

  init(id: String? = nil, title: String, items: [CommandPaletteItem]) {
    self.id = id ?? title
    self.title = title
    self.items = items
  }
}
