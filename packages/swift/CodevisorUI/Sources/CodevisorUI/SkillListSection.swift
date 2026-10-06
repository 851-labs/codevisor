import CodevisorCore
import SwiftUI

/// The skills list both apps render: one row per skill in the store, with
/// Edit… and Remove… in its menu. Skills have no enabled flag, so the row
/// carries no toggle.
public struct SkillListSection: View {
  private let model: SkillListModel
  private let onEdit: (ServerSkill) -> Void
  private let onRemove: (ServerSkill) -> Void

  public init(
    model: SkillListModel,
    onEdit: @escaping (ServerSkill) -> Void,
    onRemove: @escaping (ServerSkill) -> Void
  ) {
    self.model = model
    self.onEdit = onEdit
    self.onRemove = onRemove
  }

  public var body: some View {
    Section {
      if model.isLoading && model.skills.isEmpty {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading…").foregroundStyle(.secondary)
        }
      } else if model.skills.isEmpty {
        Text(model.loadFailed ? "Couldn’t load skills." : "No skills yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.skills) { skill in
          FleetEntryRow(
            name: skill.name,
            // A paragraph of skill prose under every row turns the list
            // into a wall of text; only a broken SKILL.md earns a caption.
            caption: skill.invalid == true ? "Invalid SKILL.md" : nil,
            icon: { Image(systemName: "book.closed") },
            actions: {
              Button("Edit…") { onEdit(skill) }
              Divider()
              Button("Remove…", role: .destructive) { onRemove(skill) }
            })
        }
      }
    }
  }
}
