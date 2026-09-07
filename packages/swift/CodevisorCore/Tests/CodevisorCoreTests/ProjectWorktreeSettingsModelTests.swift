import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Project worktree settings")
struct ProjectWorktreeSettingsModelTests {
  private let main = ProjectWorktreeBase(remote: "origin", branch: "main")
  private let develop = ProjectWorktreeBase(remote: "upstream", branch: "develop")

  @Test("An unchanged legacy base displays origin/main without writing it")
  func preservesLegacyDefault() async {
    let model = ProjectWorktreeSettingsModel(worktreeBase: nil)
    await model.load { [] }
    #expect(model.effectiveSelectedBase == main)
    let saved = await model.save { _ in
      Issue.record("An unchanged base should not be written")
      return nil
    }
    #expect(saved)
    #expect(model.savedBase == nil)
    #expect(!model.hasChanges)
  }

  @Test("Save failures retain edits for retry; success establishes the new baseline")
  func retriesSave() async {
    let model = ProjectWorktreeSettingsModel(worktreeBase: main)
    await model.load { [] }
    model.selectedBase = develop
    let failed = await model.save { base in
      #expect(base == develop)
      throw SettingsTestError.unavailable
    }
    #expect(!failed)
    #expect(model.errorMessage != nil)
    #expect(model.selectedBase == develop)
    #expect(model.savedBase == main)
    #expect(model.hasChanges)
    #expect(!model.isSaving)

    let saved = await model.save { $0 }
    #expect(saved)
    #expect(model.errorMessage == nil)
    #expect(model.savedBase == develop)
    #expect(!model.hasChanges)
  }

  @Test("Refreshes update clean editors but preserve dirty edits; Revert uses the latest baseline")
  func receivesChangesFromOtherWindow() async {
    let model = ProjectWorktreeSettingsModel(worktreeBase: nil)
    model.receive(main)
    #expect(model.selectedBase == main)
    model.selectedBase = develop
    let release = ProjectWorktreeBase(remote: "origin", branch: "release")
    model.receive(release)
    #expect(model.selectedBase == develop)
    #expect(model.savedBase == release)
    model.revert()
    #expect(model.selectedBase == release)
    #expect(!model.hasChanges)
  }

  @Test("A late branch response cannot replace a newer load")
  func ignoresOutdatedBranchLoad() async {
    let model = ProjectWorktreeSettingsModel(worktreeBase: develop)
    let started = TestSignal()
    let release = TestSignal()
    let oldLoad = Task {
      await model.load {
        started.signal()
        await release.wait()
        return [ServerProjectGitBranch(remote: "origin", branch: "old", isDefault: true)]
      }
    }
    await started.wait()
    let expected = ServerProjectGitBranch(remote: "upstream", branch: "develop", isDefault: true)
    await model.load { [expected] }
    release.signal()
    await oldLoad.value
    #expect(model.branches == [expected])
    #expect(model.selectedBase == develop)
    #expect(!model.isLoading)
  }

  @Test("Branch load failures can be retried without losing an unavailable saved selection")
  func retriesLoad() async {
    let model = ProjectWorktreeSettingsModel(worktreeBase: develop)
    await model.load { throw SettingsTestError.unavailable }
    #expect(model.errorMessage != nil)
    #expect(!model.isLoading)
    #expect(model.effectiveSelectedBase == develop)
    await model.load { [] }
    #expect(model.errorMessage == nil)
    #expect(model.effectiveSelectedBase == develop)
  }

  @Test("Saving prevents duplicate writes, reverts, and stale refreshes")
  func holdsSaveBaseline() async {
    let model = ProjectWorktreeSettingsModel(worktreeBase: main)
    await model.load { [] }
    model.selectedBase = develop
    let started = TestSignal()
    let release = TestSignal()
    let saving = Task {
      await model.save { base in
        started.signal()
        await release.wait()
        return base
      }
    }
    await started.wait()
    #expect(model.isSaving)
    model.receive(nil)
    model.revert()
    #expect(model.savedBase == main)
    #expect(model.selectedBase == develop)
    let duplicate = await model.save { _ in
      Issue.record("A save in flight must prevent a duplicate write")
      return nil
    }
    #expect(!duplicate)
    release.signal()
    let saved = await saving.value
    #expect(saved)
    #expect(model.savedBase == develop)
    #expect(!model.isSaving)
  }
}

private enum SettingsTestError: Error {
  case unavailable
}
