import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("Harness machine model")
struct HarnessMachineModelTests {
  private enum TestFailure: Error { case expected }

  @Test("Scan partitions the catalog and announces the change")
  func scanCatalog() async {
    var announcements = 0
    let ready = harness(id: "ready", ready: true)
    let unavailable = harness(id: "missing", ready: false)
    let model = configuredModel(
      rescan: { [ready, unavailable] },
      catalogDidChange: { announcements += 1 }
    )

    await model.scan()

    #expect(model.catalogState == .loaded)
    #expect(model.installedHarnesses.map(\.id) == ["ready"])
    #expect(model.notInstalledHarnesses.map(\.id) == ["missing"])
    #expect(announcements == 1)
  }

  @Test("A failed rescan retains the last useful catalog")
  func failedScanRetainsCatalog() async {
    let failure = FailureSwitch()
    let original = harness(id: "codex", ready: true)
    let model = configuredModel(rescan: {
      if failure.isEnabled { throw TestFailure.expected }
      return [original]
    })
    await model.scan()

    failure.isEnabled = true
    await model.scan()

    #expect(model.harnesses == [original])
    #expect(model.catalogErrorMessage != nil)
    #expect(!model.isScanning)
  }

  @Test("A newer scan wins over a stale light refresh")
  func scanSupersedesRefresh() async {
    let gate = CatalogGate()
    let stale = harness(id: "stale", ready: true)
    let fresh = harness(id: "fresh", ready: true)
    let model = configuredModel(
      load: { await gate.wait() },
      rescan: { [fresh] }
    )

    let refresh = Task { await model.refresh() }
    await gate.started.wait()
    await model.scan()
    await gate.resume(with: [stale])
    _ = await refresh.value

    #expect(model.harnesses.map(\.id) == ["fresh"])
  }

  @Test("Preference mutation preserves effective state and rolls back exactly")
  func preferenceMutation() async {
    let failure = FailureSwitch()
    let original = harness(id: "pi", ready: true, enabled: false, desiredEnabled: false)
    let model = configuredModel(setDesiredEnabled: { _, enabled in
      if failure.isEnabled { throw TestFailure.expected }
      return self.harness(
        id: "pi",
        ready: true,
        enabled: false,
        desiredEnabled: enabled
      )
    })
    model.replaceCatalog([original])

    await model.setDesiredEnabled(id: "pi", enabled: true)
    #expect(model.harness(id: "pi")?.isDesiredEnabled == true)
    #expect(model.harness(id: "pi")?.isEffectivelyEnabled == false)

    failure.isEnabled = true
    await model.setDesiredEnabled(id: "pi", enabled: false)
    #expect(model.harness(id: "pi")?.isDesiredEnabled == true)
    #expect(model.operationError?.title == "Couldn't turn off pi")
  }

  @Test("Completing an install requests authentication once ready")
  func completedInstallRequestsAuthentication() throws {
    var installing = harness(id: "cursor", ready: false)
    installing.lifecycle = ServerHarnessLifecycleState(phase: "installing")
    let ready = try authenticatedHarness(id: "cursor", state: "unauthenticated")

    let candidate = HarnessMachineModel.newlyInstalledHarnessRequiringAuthentication(
      previous: [installing],
      current: [ready]
    )

    #expect(candidate?.id == "cursor")
  }

  private func configuredModel(
    load: @escaping HarnessMachineModel.Dependencies.CatalogLoader = { [] },
    rescan: @escaping HarnessMachineModel.Dependencies.CatalogLoader = { [] },
    setDesiredEnabled: @escaping HarnessMachineModel.Dependencies.PreferenceSetter = { _, _ in
      throw TestFailure.expected
    },
    catalogDidChange: @escaping @MainActor () -> Void = {}
  ) -> HarnessMachineModel {
    let model = HarnessMachineModel()
    model.configure(
      for: "local",
      dependencies: HarnessMachineModel.Dependencies(
        loadCatalog: load,
        rescanCatalog: rescan,
        setDesiredEnabled: setDesiredEnabled,
        startUpdate: { _ in ServerHarnessOperationStarted(accepted: true) },
        catalogDidChange: catalogDidChange
      )
    )
    return model
  }

  private func harness(
    id: String,
    ready: Bool,
    enabled: Bool = true,
    desiredEnabled: Bool? = nil
  ) -> ServerHarness {
    ServerHarness(
      id: id,
      name: id,
      symbolName: "terminal",
      source: "builtin",
      launchKind: "executable",
      enabled: enabled,
      readiness: ServerHarnessReadiness(state: ready ? "ready" : "unavailable"),
      desiredEnabled: desiredEnabled
    )
  }

  private func authenticatedHarness(id: String, state: String) throws -> ServerHarness {
    let value: [String: Any] = [
      "id": id,
      "name": id,
      "symbolName": "terminal",
      "source": "builtin",
      "launchKind": "executable",
      "enabled": false,
      "desiredEnabled": true,
      "readiness": ["state": "ready"],
      "auth": [
        "state": state,
        "accounts": [],
        "loginMethods": [],
        "supportsMultipleAccounts": true,
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(ServerHarness.self, from: data)
  }
}

@MainActor
private final class FailureSwitch {
  var isEnabled = false
}

private actor CatalogGate {
  private var continuation: CheckedContinuation<[ServerHarness], Never>?

  nonisolated let started = TestSignal()

  func wait() async -> [ServerHarness] {
    await withCheckedContinuation {
      continuation = $0; started.signal()
    }
  }

  func resume(with harnesses: [ServerHarness]) {
    continuation?.resume(returning: harnesses)
    continuation = nil
  }
}
