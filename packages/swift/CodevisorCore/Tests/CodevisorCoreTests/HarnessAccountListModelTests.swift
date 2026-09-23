import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Harness account loading and actions")
struct HarnessAccountListModelTests {
  @Test("Initial loading never reports an empty result before the request finishes")
  func initialLoading() async throws {
    let model = HarnessAccountListModel()
    let entered = TestSignal()
    let release = TestSignal()
    let account = try account()
    let request = Task {
      await model.load {
        entered.signal()
        await release.wait()
        return [account]
      }
    }
    await entered.wait()
    #expect(model.isLoading)
    #expect(!model.hasLoaded)
    release.signal()
    await request.value
    #expect(model.hasLoaded)
    #expect(!model.isLoading)
    #expect(model.accounts == [account])
    await model.load { [] }
    #expect(model.hasLoaded && model.accounts.isEmpty)
  }

  @Test("Errors stay distinct from an empty account list, and retry recovers")
  func loadingError() async throws {
    let model = HarnessAccountListModel()
    await model.load { throw Failure.offline }
    #expect(!model.hasLoaded && !model.isLoading)
    #expect(model.errorMessage != nil)
    let account = try account()
    await model.load { [account] }
    await model.load { throw Failure.offline }
    #expect(model.hasLoaded)
    #expect(model.accounts == [account])
    #expect(model.errorMessage != nil)
    await model.load { [account] }
    #expect(model.errorMessage == nil)
  }

  @Test("A slower earlier refresh cannot replace a newer result")
  func refreshOrdering() async throws {
    let model = HarnessAccountListModel()
    let entered = TestSignal()
    let release = TestSignal()
    let account = try account()
    let old = Task {
      await model.load {
        entered.signal()
        await release.wait()
        return []
      }
    }
    await entered.wait()
    await model.load { [account] }
    release.signal()
    await old.value
    #expect(model.accounts == [account])
    #expect(model.hasLoaded && !model.isLoading)
  }

  @Test("Remove is immediate, rejects duplicate actions, and rolls back on failure")
  func optimisticRollback() async throws {
    let model = HarnessAccountListModel()
    let account = try account()
    await model.load { [account] }
    let entered = TestSignal()
    let release = TestSignal()
    let removal = Task {
      await model.perform("Removing account…", accountId: account.id, optimistic: { _ in [] }) {
        entered.signal()
        await release.wait()
        throw Failure.offline
      }
    }
    await entered.wait()
    #expect(model.accounts.isEmpty)
    #expect(model.operation == "Removing account…")
    #expect(model.workingAccountId == account.id)
    #expect(await model.perform("Duplicate") { Issue.record("Duplicate action was sent") } == false)
    await model.load {
      Issue.record("Reload must not undo a pending action"); return [account]
    }
    #expect(model.accounts.isEmpty)
    release.signal()
    #expect(await removal.value == false)
    #expect(model.accounts == [account])
    #expect(!model.isWorking && model.workingAccountId == nil)
    #expect(model.errorMessage != nil)
  }

  @Test("An in-flight refresh cannot undo a successful removal or clear its error")
  func mutationWins() async throws {
    for fails in [false, true] {
      let model = HarnessAccountListModel()
      let account = try account()
      await model.load { [account] }
      let entered = TestSignal()
      let release = TestSignal()
      let stale = Task {
        await model.load {
          entered.signal()
          await release.wait()
          return [account]
        }
      }
      await entered.wait()
      #expect(model.accounts == [account])
      await model.perform("Removing account…", optimistic: { _ in [] }) {
        if fails { throw Failure.offline }
      }
      release.signal()
      await stale.value
      #expect(model.accounts == (fails ? [account] : []))
      #expect((model.errorMessage != nil) == fails)
      #expect(!model.isWorking && !model.isLoading)
    }
  }

  @Test("Discovery's empty slot becomes a sign-in target, not a visible account")
  func emptyDefaultAccount() async throws {
    let model = HarnessAccountListModel()
    var empty = try account()
    empty.profileKind = "default"
    empty.authState = "unauthenticated"
    empty.canLogout = false
    await model.load { [empty] }
    #expect(model.hasLoaded && model.accounts.isEmpty)
    #expect(model.accountForSignIn?.id == empty.id)
    var expired = empty
    expired.authState = "expired"
    await model.load { [expired] }
    #expect(model.accounts == [expired])
    #expect(model.emptyDefaultAccount == nil)
    var named = empty
    named.profileKind = "managed"
    await model.load { [named] }
    #expect(model.accounts == [named])
    #expect(model.accountForSignIn?.id == named.id)
  }

  /// The sheet chrome renders `operation` and gates interactive dismiss on
  /// it, so a label that is missing while work runs — or lingers after it —
  /// is either an invisible operation or a sheet the user cannot close.
  /// `isWorking` must never disagree with it.
  @Test("A running operation always carries its label, and clears it on success")
  func operationLabelTracksWork() async throws {
    let model = HarnessAccountListModel()
    #expect(model.operation == nil && !model.isWorking)

    let entered = TestSignal()
    let release = TestSignal()
    let account = try account()
    let work = Task {
      await model.perform("Signing out…", accountId: account.id) {
        entered.signal()
        await release.wait()
      }
    }
    await entered.wait()
    #expect(model.operation == "Signing out…")
    #expect(model.isWorking == (model.operation != nil))
    release.signal()
    #expect(await work.value)
    #expect(model.operation == nil)
    #expect(model.isWorking == (model.operation != nil))
  }

  private enum Failure: Error { case offline }

  private func account() throws -> ServerHarnessAccount {
    try JSONDecoder().decode(
      ServerHarnessAccount.self,
      from: Data(
        """
        {"id":"account","harnessId":"claude-code","label":"person@example.com", "profileKind":"managed",
        "authState":"authenticated","isActive":true,"canLogin":true,"canLogout":true}
        """.utf8))
  }
}
