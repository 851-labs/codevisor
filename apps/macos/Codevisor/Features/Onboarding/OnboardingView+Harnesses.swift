import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import UniformTypeIdentifiers
import os
import CodevisorUI

extension OnboardingView {
  // MARK: - Harnesses

  var harnessesStep: some View {
    VStack(spacing: 20) {
      stepHeader(
        symbol: "terminal",
        title: "Choose your harnesses",
        subtitle: "These are the ACP coding agents we found on your Mac. Turn on the ones you'd like to use."
      )

      switch detection {
      case .connecting:
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Checking agents…")
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
      case let .unreachable(message):
        VStack(spacing: 12) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Can't reach the Codevisor server").fontWeight(.medium)
              Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.statusWarn)
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
          Button {
            Task { await detectHarnesses() }
          } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
          }
        }
      case .loaded:
        if installedHarnesses.isEmpty {
          noHarnessesContent
        } else {
          VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
              ForEach(Array(installedHarnesses.enumerated()), id: \.element.id) { index, harness in
                harnessRow(harness)
                if index < installedHarnesses.count - 1 { Divider() }
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))

            if !notInstalledHarnesses.isEmpty {
              DisclosureGroup(isExpanded: $showsNotInstalled) {
                notInstalledList
                  .padding(.top, 8)
              } label: {
                Text("Not installed (\(notInstalledHarnesses.count))")
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// The "nothing installed" empty state: every known harness with an
  /// install hint, plus a rescan that picks up a fresh install in place —
  /// the server re-resolves its PATH, so no relaunch is needed.
  private var noHarnessesContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text("No harnesses found").fontWeight(.medium)
          Text("Install one below, then detect again — no restart needed.")
            .font(.callout).foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.statusWarn)
      }

      notInstalledList

      Button {
        Task { await rescanHarnesses() }
      } label: {
        if isRescanning {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Detecting…")
          }
        } else {
          Label("Detect again", systemImage: "arrow.clockwise")
        }
      }
      .disabled(isRescanning)

      if let rescanError {
        Text(rescanError)
          .font(.callout)
          .foregroundStyle(theme.statusWarn)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var notInstalledList: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(notInstalledHarnesses.enumerated()), id: \.element.id) { index, harness in
        HarnessInstallHintRow(harness: harness)
          .padding(.vertical, 8)
        if index < notInstalledHarnesses.count - 1 { Divider() }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
  }

  private func harnessRow(_ harness: ServerHarness) -> some View {
    HStack(spacing: 12) {
      HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 18)
        .frame(width: 34, height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardHoverBackground))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(harness.name)
          .fontWeight(.medium)
        // One line, exactly like every other harness row — an errored
        // probe must not make this row taller than its neighbours. The
        // full text stays reachable as a tooltip.
        Text(authStatus(harness))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(authStatus(harness))
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if harness.requiresAuthentication {
        Button("Sign In…") { authenticationHarness = harness }
      } else {
        if harness.auth?.supportsMultipleAccounts == true {
          Button("Accounts…") { authenticationHarness = harness }
        }
      }
      Toggle(
        "Enable \(harness.name)",
        isOn: Binding(
          get: { harness.isDesiredEnabled },
          set: { enabled in Task { await setHarness(harness, enabled: enabled) } }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
    }
    .padding(.vertical, 10)
  }

  private func authStatus(_ harness: ServerHarness) -> String {
    guard let auth = harness.auth else { return "Sign-in status unavailable" }
    let account = auth.accounts.first(where: { $0.id == auth.activeAccountId }) ?? auth.accounts.first
    switch auth.resolvedState {
    case .authenticated: return account?.email.map { "Signed in as \($0)" } ?? "Signed in"
    case .notRequired: return "No sign-in required"
    case .checking: return "Checking sign-in…"
    case .expired: return "Sign-in expired"
    // Deliberately plain language, and deliberately not the probe's
    // `detail`: that carries a crashed CLI's stderr, which was rendering
    // here as kilobytes of minified JavaScript. The technical cause is
    // still summarized and persisted server-side for diagnosis.
    case .error: return "Something went wrong starting the CLI"
    case .unauthenticated, .unavailable, .unknown: return "Not signed in"
    }
  }

  private func setHarness(_ harness: ServerHarness, enabled: Bool) async {
    updateHarnessDesiredEnabled(harness.id, enabled: enabled)
    do {
      let updated = try await environment.machines.client(for: CodevisorMachine.local.id)
        .setHarnessDesiredEnabled(id: harness.id, enabled: enabled)
      environment.settings.setHarness(harness.id, enabled: updated.isDesiredEnabled)
      replaceHarness(updated)
    } catch {
      replaceHarness(harness)
      Log.server.error(
        "Setting harness \(harness.id, privacy: .public) enabled=\(enabled, privacy: .public) during onboarding failed: \(String(describing: error), privacy: .public)"
      )
      toggleError = ToggleError(
        title: enabled ? "Couldn't turn on \(harness.name)" : "Couldn't turn off \(harness.name)",
        message: ErrorReporter.userFacingMessage(for: error)
      )
    }
  }

  private func updateHarnessDesiredEnabled(_ id: String, enabled: Bool) {
    guard let index = harnesses.firstIndex(where: { $0.id == id }) else { return }
    harnesses[index].desiredEnabled = enabled
  }

  func replaceHarness(_ harness: ServerHarness) {
    guard let index = harnesses.firstIndex(where: { $0.id == harness.id }) else { return }
    harnesses[index] = harness
  }

  // MARK: - Detection

  /// Waits for the local server, then loads the harness catalog with a
  /// short retry tail. Onboarding shows on first launch — exactly when the
  /// server is cold-starting — so querying immediately used to hit a closed
  /// port and misreport "No harnesses found".
  /// Light refetch (no PATH re-resolve) when a lifecycle event invalidated
  /// the catalog — flips rows through Installing… → installed live.
  func refreshHarnessList() async {
    guard detection == .loaded else { return }
    if let loaded = try? await environment.harnessService(for: CodevisorMachine.local.id).allHarnesses() {
      harnesses = loaded
    }
  }

  func detectHarnesses() async {
    detection = .connecting
    projectSetup.isLoadingRecommendations = true
    if !AppPreview.isRunning {
      // Joins the root view's in-flight server start (ensureRunning
      // dedups concurrent callers) instead of racing ahead of it.
      await environment.prepareMachine(CodevisorMachine.local.id)
    }
    // Safety net past the health wait: a handful of quick retries, not
    // one instantly-failing shot.
    for attempt in 0..<8 {
      if let loaded = try? await environment.harnessService(for: CodevisorMachine.local.id)
        .rescanHarnesses()
      {
        harnesses = loaded
        detection = .loaded
        // Suggest project folders from the user's most recent harness
        // sessions so the project step offers one-click choices.
        projectSetup.recommendations = await environment.recommendedProjectsWithFallback(
          serverId: CodevisorMachine.local.id
        )
        projectSetup.isLoadingRecommendations = false
        return
      }
      if attempt < 7 {
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
    projectSetup.isLoadingRecommendations = false
    detection = .unreachable(serverFailureMessage)
  }

  /// Re-detects on demand after the user installs a CLI; the server
  /// re-resolves its PATH first.
  private func rescanHarnesses() async {
    isRescanning = true
    defer { isRescanning = false }
    do {
      harnesses = try await environment.harnessService(for: CodevisorMachine.local.id)
        .rescanHarnesses()
      rescanError = nil
    } catch {
      Log.onboarding.error("Harness rescan failed: \(String(describing: error), privacy: .public)")
      rescanError =
        "Couldn't check for installed agents. Make sure the Codevisor server is running, then try again."
    }
  }

  private var serverFailureMessage: String {
    if case let .unavailable(message) = environment.localServer?.state {
      return message
    }
    return "The Codevisor server didn't respond. Try again, or check Settings → Machines."
  }
}
