struct CommandPaletteSection: Identifiable {
  let title: String
  let items: [CommandPaletteItem]

  var id: String { title }
}
