import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
final class CloudSessionValidation {
  nonisolated static let maxRetryDelay: Duration = .seconds(60)
  private nonisolated static let maxBackoffExponent = 6

  private(set) var hasCompletedBootstrap = false
  private(set) var isRosterVerified = false
  @ObservationIgnored private(set) var task: Task<Void, Never>?
  @ObservationIgnored private(set) var retryTask: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var failures = 0
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let credentials: CloudCredentialCache
  @ObservationIgnored private let pins: CloudMachineKeyPinCache
  @ObservationIgnored private let rosterStore: any CloudCredentialStore

  init(
    clock: any Clock<Duration>,
    credentials: CloudCredentialCache,
    pins: CloudMachineKeyPinCache,
    rosterStore: any CloudCredentialStore
  ) {
    self.clock = clock
    self.credentials = credentials
    self.pins = pins
    self.rosterStore = rosterStore
  }

  func bootstrap(for account: CloudAccountController) async {
    guard !hasCompletedBootstrap else { return }
    await credentials.load()
    guard credentials.current.token != nil else {
      await bootstrapSignedOut(account)
      return
    }
    if let roster = restoreCachedRoster(for: account) {
      resume(account, from: roster)
      return
    }
    await bootstrapByValidating(account)
  }

  func retryIfUnverified(for account: CloudAccountController) async {
    guard awaitsVerification(of: account) else { return }
    if let task {
      await task.value
      return
    }
    cancelRetry()
    failures = 0
    await start(for: account).value
  }

  func rosterVerified(_ roster: CachedRoster) {
    isRosterVerified = true
    failures = 0
    cancelRetry()
    rosterStore.saveRoster(roster)
  }

  func unverify() {
    cancel()
    isRosterVerified = false
  }

  func discardRoster() {
    unverify()
    rosterStore.clearRoster()
  }

  func scheduleRetry(for account: CloudAccountController) {
    guard account.state.isSignedIn else { return }
    retryTask?.cancel()
    failures += 1
    let delay = Self.retryDelay(afterFailures: failures)
    let revision = account.authenticationRevision
    let clock = clock
    retryTask = Task { [weak self, weak account] in
      do {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
      guard let self, let account else { return }
      self.retryIfStillUnverified(account, revision: revision)
    }
  }

  nonisolated static func isSessionRejection(_ error: any Error) -> Bool {
    if case CloudAccountClientError.httpStatus(401) = error { return true }
    return false
  }

  nonisolated static func retryDelay(afterFailures failures: Int) -> Duration {
    let exponent = min(failures - 1, maxBackoffExponent)
    return min(maxRetryDelay, .seconds(1 << exponent))
  }

  private func bootstrapSignedOut(_ account: CloudAccountController) async {
    rosterStore.clearRoster()
    defer { markBootstrappedUnlessCancelled() }
    await account.refreshAuthProviders()
    account.state = .signedOut
  }

  private func resume(_ account: CloudAccountController, from roster: CachedRoster) {
    account.userId = roster.userId
    account.state = .signedIn(userEmail: roster.userEmail)
    account.machines = roster.machines
    hasCompletedBootstrap = true
    start(for: account)
  }

  private func bootstrapByValidating(_ account: CloudAccountController) async {
    defer { markBootstrappedUnlessCancelled() }
    if !account.state.isSignedIn { account.state = .validating }
    await (task ?? start(for: account)).value
  }

  private func markBootstrappedUnlessCancelled() {
    if !Task.isCancelled { hasCompletedBootstrap = true }
  }

  private func restoreCachedRoster(for account: CloudAccountController) -> CachedRoster? {
    guard let roster = rosterStore.loadRoster() else { return nil }
    guard roster.serverURL == account.serverURL.absoluteString else {
      rosterStore.clearRoster()
      return nil
    }
    return roster
  }

  @discardableResult
  private func start(for account: CloudAccountController) -> Task<Void, Never> {
    generation &+= 1
    let generation = generation
    let revision = account.authenticationRevision
    let task = Task { [weak self, weak account] in
      guard let self, let account else { return }
      await self.validate(account, revision: revision)
      if self.generation == generation {
        self.task = nil
      }
    }
    self.task = task
    return task
  }

  private func validate(_ account: CloudAccountController, revision: UInt64) async {
    guard account.authenticationRevision == revision, let token = credentials.current.token else { return }
    try? await pins.prepare()
    let user: CloudSessionUser?
    do {
      user = try await account.client.session(token: token)
    } catch is CancellationError {
      return
    } catch {
      validationFailed(error, account: account, revision: revision)
      return
    }
    await validated(user, account: account, revision: revision)
  }

  private func validationFailed(_ error: any Error, account: CloudAccountController, revision: UInt64) {
    guard account.authenticationRevision == revision else { return }
    Log.cloud.error("Cloud session validation failed: \(String(describing: error), privacy: .public)")
    account.lastError = error.localizedDescription
    if Self.isSessionRejection(error) {
      account.sessionEnded()
      return
    }
    if !account.state.isSignedIn { account.state = .signedIn(userEmail: nil) }
    scheduleRetry(for: account)
  }

  private func validated(_ user: CloudSessionUser?, account: CloudAccountController, revision: UInt64) async {
    guard account.authenticationRevision == revision else { return }
    guard let user else {
      account.sessionEnded()
      return
    }
    account.userId = user.userId
    account.state = .signedIn(userEmail: user.email)
    guard await account.performMachineRefresh().needsValidationRetry,
      account.authenticationRevision == revision
    else { return }
    scheduleRetry(for: account)
  }

  private func retryIfStillUnverified(_ account: CloudAccountController, revision: UInt64) {
    guard !Task.isCancelled, account.authenticationRevision == revision else { return }
    retryTask = nil
    guard awaitsVerification(of: account), task == nil else { return }
    start(for: account)
  }

  private func awaitsVerification(of account: CloudAccountController) -> Bool {
    account.state.isSignedIn && !isRosterVerified
  }

  private func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
    cancelRetry()
    failures = 0
  }

  private func cancelRetry() {
    retryTask?.cancel()
    retryTask = nil
  }
}
