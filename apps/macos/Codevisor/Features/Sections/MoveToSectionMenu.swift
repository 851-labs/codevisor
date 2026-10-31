import CodevisorCore
import SwiftUI

struct MoveToSectionMenu: View {
  let currentSectionID: UUID?
  let sections: [CustomSection]
  let move: (UUID?) -> Void
  let newSection: () -> Void

  var body: some View {
    Menu {
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
      Button(action: newSection) {
        Label("New Section…", systemImage: "folder.badge.plus")
          .labelStyle(.titleAndIcon)
      }
    } label: {
      Label("Move to Section", systemImage: "folder")
        .labelStyle(.titleAndIcon)
    }
  }

  private var section: Binding<UUID?> {
    Binding(get: { currentSectionID }, set: move)
  }
}
