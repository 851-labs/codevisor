import SwiftUI

struct PluginAppSubjectPlaceholder: View {
  let state: PluginAppSubjectLookup.State
  let restriction: String?
  let onRetry: () -> Void

  static func isBlocking(_ state: PluginAppSubjectLookup.State, restriction: String?) -> Bool {
    switch state {
    case .missing, .failed: true
    case .idle, .checking, .found: restriction != nil
    }
  }

  var body: some View {
    if let restriction {
      PluginAppInlinePlaceholder(systemImage: "hand.raised", message: restriction)
    } else if case let .failed(message) = state {
      PluginAppInlinePlaceholder(systemImage: "exclamationmark.triangle", message: message, action: onRetry)
    } else {
      PluginAppInlinePlaceholder(
        systemImage: "puzzlepiece.extension", message: "This plugin is no longer installed on that machine.")
    }
  }
}
