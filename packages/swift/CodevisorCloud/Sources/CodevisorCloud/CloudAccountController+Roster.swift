import CodevisorClient
import Foundation

enum MachineRefreshOutcome {
  case succeeded
  case failed(any Error)
  case skipped
}

extension CloudAccountController {
  static let maxValidationRetryDelay: Duration = .seconds(60)

  public func bootstrap() async {
    guard !hasCompletedBootstrap else { return }
    await loadCredentials()
    guard storedToken != nil else {
      credentialStore.clearRoster()
      defer {
        if !Task.isCancelled { hasCompletedBootstrap = true }
      }
      await refreshAuthProviders()
      state = .signedOut
      return
    }
    if let roster = restoreCachedRoster() {
      state = .signedIn(userEmail: roster.userEmail)
      machines = roster.machines
      hasCompletedBootstrap = true
      startSessionValidation()
      return
    }
    defer {
      if !Task.isCancelled { hasCompletedBootstrap = true }
    }
    if !state.isSignedIn { state = .validating }
    let attempt = validationTask ?? startSessionValidation()
    await attempt.value
  }

  public func retryIfUnverified() async {
    guard state.isSignedIn, !isRosterVerified else { return }
    if let validationTask {
      await validationTask.value
      return
    }
    validationRetryTask?.cancel()
    validationRetryTask = nil
    validationFailures = 0
    await startSessionValidation().value
  }

  static func isSessionRejection(_ error: any Error) -> Bool {
    if case CloudAccountClientError.httpStatus(401) = error { return true }
    return false
  }

  func didVerifyRoster() {
    isRosterVerified = true
    validationFailures = 0
    validationRetryTask?.cancel()
    validationRetryTask = nil
    let email: String? = if case let .signedIn(email) = state { email } else { nil }
    credentialStore.saveRoster(
      CachedRoster(serverURL: serverURL.absoluteString, userEmail: email, machines: machines))
  }

  func cancelSessionValidation() {
    validationGeneration &+= 1
    validationTask?.cancel()
    validationTask = nil
    validationRetryTask?.cancel()
    validationRetryTask = nil
    validationFailures = 0
  }

  func refreshAuthProvidersIfUnknown() {
    guard authProviders == nil else { return }
    let server = serverURL
    let client = clientFactory(server)
    Task { [weak self] in
      guard let providers = try? await client.discover().authProviders else { return }
      guard let self, self.serverURL == server, self.authProviders == nil else { return }
      self.authProviders = providers
    }
  }

  private func restoreCachedRoster() -> CachedRoster? {
    guard let roster = credentialStore.loadRoster() else { return nil }
    guard roster.serverURL == serverURL.absoluteString else {
      credentialStore.clearRoster()
      return nil
    }
    return roster
  }

  @discardableResult
  private func startSessionValidation() -> Task<Void, Never> {
    validationGeneration &+= 1
    let generation = validationGeneration
    let revision = authenticationRevision
    let task = Task { [weak self] in
      guard let self else { return }
      await self.validateSession(revision: revision)
      if self.validationGeneration == generation {
        self.validationTask = nil
      }
    }
    validationTask = task
    return task
  }

  private func validateSession(revision: UInt64) async {
    guard authenticationRevision == revision, let token = storedToken else { return }
    try? await machineKeyPins.prepare()
    let user: CloudSessionUser?
    do {
      user = try await client.session(token: token)
    } catch is CancellationError {
      return
    } catch {
      guard authenticationRevision == revision else { return }
      Log.cloud.error("Cloud session validation failed: \(String(describing: error), privacy: .public)")
      lastError = error.localizedDescription
      if Self.isSessionRejection(error) {
        sessionEnded()
        return
      }
      if !state.isSignedIn { state = .signedIn(userEmail: nil) }
      scheduleSessionValidationRetry()
      return
    }
    guard authenticationRevision == revision else { return }
    guard let user else {
      sessionEnded()
      return
    }
    state = .signedIn(userEmail: user.email)
    if case let .failed(error) = await performMachineRefresh(), !Self.isSessionRejection(error) {
      guard authenticationRevision == revision else { return }
      scheduleSessionValidationRetry()
    }
  }

  func scheduleSessionValidationRetry() {
    guard state.isSignedIn else { return }
    validationRetryTask?.cancel()
    validationFailures += 1
    let exponent = min(validationFailures - 1, 6)
    let delay = min(Self.maxValidationRetryDelay, .seconds(1 << exponent))
    let revision = authenticationRevision
    let clock = retryClock
    validationRetryTask = Task { [weak self] in
      do {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
      guard let self, !Task.isCancelled, self.authenticationRevision == revision else { return }
      self.validationRetryTask = nil
      guard self.state.isSignedIn, !self.isRosterVerified, self.validationTask == nil else { return }
      self.startSessionValidation()
    }
  }
}
