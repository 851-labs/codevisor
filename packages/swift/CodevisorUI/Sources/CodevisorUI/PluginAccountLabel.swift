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

  private var title: String {
    account.label ?? account.identity ?? fallbackName
  }

  private var subtitle: String? {
    guard account.label != nil else { return nil }
    return account.identity
  }
}
