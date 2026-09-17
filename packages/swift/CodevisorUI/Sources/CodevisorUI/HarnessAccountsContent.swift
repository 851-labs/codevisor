import CodevisorCore
import SwiftUI

/// Stable sheet content for initial loading, sign-in, and account changes.
public struct HarnessAccountsContent<Accounts: View, SignIn: View>: View {
  let harnessId: String
  let harnessName: String
  let model: HarnessAccountListModel
  let retry: () async -> Void
  let accounts: Accounts
  let signIn: SignIn

  public init(
    harnessId: String, harnessName: String, model: HarnessAccountListModel, retry: @escaping () async -> Void,
    @ViewBuilder accounts: () -> Accounts, @ViewBuilder signIn: () -> SignIn
  ) {
    self.harnessId = harnessId
    self.harnessName = harnessName
    self.model = model
    self.retry = retry
    self.accounts = accounts()
    self.signIn = signIn()
  }

  public var body: some View {
    VStack(spacing: 0) {
      if !model.hasLoaded {
        if model.isLoading {
          HarnessAccountsLoadingView()
        } else {
          ContentUnavailableView {
            Label("Couldn't Load Accounts", systemImage: "exclamationmark.triangle")
          } description: {
            Text(model.errorMessage ?? "Try again.")
          } actions: {
            Button("Retry") { Task { await retry() } }
          }
        }
      } else if model.accounts.isEmpty {
        HarnessSignInInvitation(harnessId: harnessId, harnessName: harnessName, errorMessage: model.errorMessage) {
          signIn.disabled(model.isWorking)
        }
      } else {
        accounts
      }
      if let operation = model.operation {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(operation).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .preference(key: HarnessAccountsWorkingPreference.self, value: model.isWorking)
  }

}

public struct HarnessAccountsWorkingPreference: PreferenceKey {
  public static let defaultValue = false

  public static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}
