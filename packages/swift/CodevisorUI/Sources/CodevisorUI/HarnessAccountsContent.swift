import CodevisorCore
import SwiftUI

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
          SheetLoadingView("Loading accounts…")
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
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .harnessWorking(model.operation)
  }
}

public struct HarnessAccountsWorkingPreference: PreferenceKey {
  public static let defaultValue: String? = nil

  public static func reduce(value: inout String?, nextValue: () -> String?) {
    value = value ?? nextValue()
  }
}

extension View {
  public func harnessWorking(_ operation: String?) -> some View {
    preference(key: HarnessAccountsWorkingPreference.self, value: operation)
  }
}
