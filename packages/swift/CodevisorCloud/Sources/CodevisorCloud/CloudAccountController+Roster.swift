import CodevisorClient
import Foundation

/// How one network roster fetch ended.
enum MachineRefreshOutcome {
  case succeeded
  case failed(any Error)
  /// Not attempted or superseded (signed out, cancelled, credentials changed
  /// mid-flight). Whoever superseded it owns the next step, so no retry.
  case skipped
}

// MARK: - Launch, cached roster, and session validation

extension CloudAccountController {
  /// The longest wait between validation attempts while the cloud is
  /// unreachable. Long enough not to hammer a down server, short enough that
  /// the list heals within a minute of connectivity returning.
  static let maxValidationRetryDelay: Duration = .seconds(60)

  /// Boot: restore whatever session is stored. With a stored token and a
  /// cached roster the signed-in state and machines are published before the
  /// first suspension point, so the UI renders instantly; validation then
  /// runs in the background. Only a server that explicitly rejects the
  /// session signs out — an unreachable one keeps the user signed in and
  /// retries with backoff. Development builds sign into the dev cloud
  /// exactly as production signs into the hosted one.
  public func bootstrap() async {
    guard !hasCompletedBootstrap else { return }
    guard storedToken != nil else {
      // A roster without a session is a leftover from a sign-out that
      // could not clear it; it must never resurface on the next sign-in.
      credentialStore.clearRoster()
      defer {
        if !Task.isCancelled { hasCompletedBootstrap = true }
      }
      // Only the sign-in screen needs the provider list, so only
      // signed-out launches pay for discovery up front.
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
    // No cache (first launch after install or upgrade): the machine list is
    // genuinely unknown, so launch waits for the first attempt as before.
    let attempt = validationTask ?? startSessionValidation()
    await attempt.value
  }

  /// Validates now when the roster on screen is still the unverified cache —
  /// the app calls this on foreground, when connectivity has likely changed.
  /// Skips any pending backoff sleep; an attempt already in flight is
  /// awaited rather than duplicated.
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

  /// A 401 is the server saying the session is gone; everything else
  /// (transport errors, timeouts, 5xx, garbled responses) says nothing about
  /// the session and must not sign the user out.
  static func isSessionRejection(_ error: any Error) -> Bool {
    if case CloudAccountClientError.httpStatus(401) = error { return true }
    return false
  }

  /// Called by the machine refresh after publishing a fetched list.
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

  /// Sign-out may follow a token launch that skipped discovery; fetch the
  /// providers then so the sign-in screen offers the right buttons. The
  /// server is captured up front because `setCustomServer` signs out before
  /// switching — an answer from the old server must not land on the new one.
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

  /// Loads the persisted roster, discarding one fetched from a different
  /// cloud server: its device ids mean nothing on the current instance.
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

  /// One validation attempt: confirm the session, then fetch the roster.
  private func validateSession(revision: UInt64) async {
    guard authenticationRevision == revision, let token = storedToken else { return }
    // Load the key pins alongside the session check so relay configs for
    // the cached machines can be issued as soon as the hub is reachable,
    // even while the REST API is still failing.
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
        signOut()
        return
      }
      if !state.isSignedIn { state = .signedIn(userEmail: nil) }
      scheduleSessionValidationRetry()
      return
    }
    guard authenticationRevision == revision else { return }
    guard let user else {
      // The server answered and holds no such session: revoked elsewhere.
      signOut()
      return
    }
    state = .signedIn(userEmail: user.email)
    if case let .failed(error) = await performMachineRefresh(), !Self.isSessionRejection(error) {
      guard authenticationRevision == revision else { return }
      scheduleSessionValidationRetry()
    }
  }

  /// Schedules the next attempt with capped exponential backoff
  /// (1s, 2s, 4s, … 60s) on the injected clock.
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
