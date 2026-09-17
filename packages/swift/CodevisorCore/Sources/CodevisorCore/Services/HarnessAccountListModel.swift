import Foundation
import Observation

/// Keeps background account refreshes from replacing a newer user action.
@MainActor @Observable public final class HarnessAccountListModel {
  public var accounts: [ServerHarnessAccount] = []
  public private(set) var hasLoaded = false
  public private(set) var isLoading = true
  public private(set) var operation: String?
  public private(set) var workingAccountId: String?
  public var errorMessage: String?
  public private(set) var emptyDefaultAccount: ServerHarnessAccount?

  public var accountForSignIn: ServerHarnessAccount? {
    let candidates = accounts.filter { $0.canLogin && $0.authState != "authenticated" && $0.authState != "notRequired" }
    return candidates.first(where: \.isActive) ?? candidates.first ?? emptyDefaultAccount
  }
  private var revision = 0

  public var isWorking: Bool { operation != nil }

  public init() {}

  public func load(_ request: () async throws -> [ServerHarnessAccount]) async {
    guard !isWorking else { return }
    revision += 1
    let current = revision
    isLoading = true
    do {
      let result = try await request()
      guard current == revision else { return }
      emptyDefaultAccount = result.first(where: \.isEmptyDefaultAccount)
      accounts = result.filter { !$0.isEmptyDefaultAccount }
      hasLoaded = true
      errorMessage = nil
    } catch {
      guard current == revision else { return }
      errorMessage = serverErrorMessage(error)
    }
    isLoading = false
  }

  @discardableResult
  public func perform(
    _ label: String, accountId: String? = nil,
    optimistic: ([ServerHarnessAccount]) -> [ServerHarnessAccount] = { $0 },
    action: () async throws -> Void
  ) async -> Bool {
    guard !isWorking else { return false }
    revision += 1
    isLoading = false
    let previous = accounts
    accounts = optimistic(previous)
    operation = label
    workingAccountId = accountId
    errorMessage = nil
    defer {
      operation = nil
      workingAccountId = nil
    }
    do {
      try await action()
      return true
    } catch {
      accounts = previous
      errorMessage = serverErrorMessage(error)
      return false
    }
  }
}
