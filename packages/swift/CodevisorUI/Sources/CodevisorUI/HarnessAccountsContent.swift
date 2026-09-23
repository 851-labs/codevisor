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

/// Carries the running operation's label from the content up to whichever
/// chrome renders it — `SheetFooter(status:)` on macOS, the confirmation
/// toolbar slot on iOS — and, by being non-nil at all, drives
/// `.interactiveDismissDisabled` so a sign-in cannot be dismissed mid-flight.
public struct HarnessAccountsWorkingPreference: PreferenceKey {
  public static let defaultValue: String? = nil

  public static func reduce(value: inout String?, nextValue: () -> String?) {
    value = value ?? nextValue()
  }
}

extension View {
  /// The **only** place the working preference is emitted.
  ///
  /// Must be applied to a non-lazy container that is unconditionally in the
  /// hierarchy. A `Form`/`List` row would drop it the moment that row
  /// scrolls out of view — macOS lazy rows only report preferences while
  /// realized — which silently flips the sheet back to dismissable in the
  /// middle of an OAuth flow. Likewise never place it inside an `if`.
  ///
  /// Preferences also do not cross a `.navigationDestination` push, so a
  /// pushed editor needs its own chrome rather than relying on this
  /// reaching the presenting sheet.
  public func harnessWorking(_ operation: String?) -> some View {
    preference(key: HarnessAccountsWorkingPreference.self, value: operation)
  }
}
