import ACPKit
import SwiftUI

struct ComposerSlashItem: Identifiable {
  let name: String
  let description: String
  var source: SessionSkillSource? = nil
  var insertion: String? = nil
  var action: (@MainActor () -> Void)? = nil

  var title: String { insertion ?? "/\(name)" }

  var id: String { action == nil ? "skill:\(title)" : "command:\(name)" }
}

extension ComposerSlashItem {
  init(skill: SessionSkill) {
    self.init(
      name: skill.name,
      description: skill.description ?? "",
      source: skill.source,
      insertion: skill.invocation
    )
  }
}
