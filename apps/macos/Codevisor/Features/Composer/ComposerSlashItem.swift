import ACPKit
import SwiftUI

/// A row in the slash-command popup: either a skill (accepted by rewriting
/// the token to the harness's exact invocation) or a local app command
/// whose acceptance runs an action and clears the token.
struct ComposerSlashItem: Identifiable {
  let name: String
  let description: String
  /// Present only on skills: where the skill comes from, for the row's
  /// trailing label.
  var source: SessionSkillSource? = nil
  /// Present only on skills: the text that replaces the token, e.g.
  /// "/code-review" or "$code-review".
  var insertion: String? = nil
  /// Present only on local commands (e.g. /plan, /goal).
  var action: (@MainActor () -> Void)? = nil

  /// What the row shows as its title: what accepting it inserts.
  var title: String { insertion ?? "/\(name)" }

  /// A harness may offer a skill with a local command's name, so the two
  /// kinds never share an identity.
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
