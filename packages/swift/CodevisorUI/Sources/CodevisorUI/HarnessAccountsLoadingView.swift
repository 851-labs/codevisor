import SwiftUI

public struct HarnessAccountsLoadingView: View {
  public init() {}

  public var body: some View {
    ProgressView("Loading accounts…")
      .controlSize(.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
