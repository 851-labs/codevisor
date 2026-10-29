import CodevisorCore
import SwiftUI

public struct PluginAccountLabel: View {
  let account: ServerPluginAccount
  let fallbackName: String

  public init(account: ServerPluginAccount, fallbackName: String) {
    self.account = account
    self.fallbackName = fallbackName
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if account.needsReauthorization {
        Label("Sign in again", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  var title: String {
    account.label ?? account.identity ?? fallbackName
  }

  var subtitle: String? {
    guard let label = account.label, let identity = account.identity else { return nil }
    guard label.caseInsensitiveCompare(identity) != .orderedSame else { return nil }
    return identity
  }
}
