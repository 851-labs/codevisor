import SwiftUI

/// A row in the slash-command popup: either a harness-advertised command
/// (accepted by rewriting the composer to "/name ") or a local app command
/// whose acceptance runs an action and clears the composer.
struct ComposerSlashItem: Identifiable {
  let name: String
  let description: String
  var hint: String? = nil
  /// Present only on local commands (e.g. /plan, /goal).
  var action: (@MainActor () -> Void)? = nil

  var id: String { name }
}
