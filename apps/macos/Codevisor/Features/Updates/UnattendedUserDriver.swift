import Foundation
import Sparkle

/// Sparkle user driver that can run one update session with no UI at all.
///
/// Attended sessions forward every call to Sparkle's stock
/// `SPUStandardUserDriver`, so menu- and banner-initiated updates keep the
/// native windows. When `beginUnattendedSession()` has armed the driver —
/// used when a REMOTE client asked this machine's server to update — the
/// session auto-accepts the install and relaunch and shows nothing: a remote
/// MacBook must never sit on a Sparkle prompt no one is present to click.
@MainActor
final class UnattendedUserDriver: NSObject, SPUUserDriver {
  private let standard: SPUStandardUserDriver
  private(set) var unattended = false
  /// The reply Sparkle is waiting on while the standard driver shows a
  /// prompt ("update found" / "ready to install"). Captured so a remote
  /// request can take over the session: without it, arming mid-session
  /// would leave that prompt open forever on a screen nobody is watching.
  private var pendingChoiceReply: ((SPUUserUpdateChoice) -> Void)?
  private var pendingPermissionReply: ((SUUpdatePermissionResponse) -> Void)?

  init(hostBundle: Bundle) {
    standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
  }

  /// Arms the CURRENT OR NEXT update session to run headless. The flag
  /// clears itself when the session ends (installed, no update, error, or
  /// dismissed), so later user-initiated checks get the standard UI again.
  ///
  /// Taking over a session already showing the standard UI — a background
  /// check found this update and parked its prompt on this machine's
  /// screen before the remote request arrived — answers the pending
  /// prompt with "install" and dismisses the visible window, so the
  /// update proceeds instead of waiting for a click that will never come.
  func beginUnattendedSession() {
    unattended = true
    if let reply = pendingPermissionReply {
      pendingPermissionReply = nil
      reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }
    if let reply = pendingChoiceReply {
      pendingChoiceReply = nil
      reply(.install)
    }
    standard.dismissUpdateInstallation()
  }

  private func endUnattendedSession() {
    unattended = false
  }

  // MARK: - SPUUserDriver

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    guard unattended else {
      pendingPermissionReply = reply
      standard.show(request) { [weak self] response in
        // A nil pending reply means an unattended takeover already
        // answered Sparkle; a late standard-UI reply must not double
        // up.
        guard let self, self.pendingPermissionReply != nil else { return }
        self.pendingPermissionReply = nil
        reply(response)
      }
      return
    }
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    guard unattended else {
      standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
      return
    }
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem,
    state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    guard unattended else {
      pendingChoiceReply = reply
      standard.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
        guard let self, self.pendingChoiceReply != nil else { return }
        self.pendingChoiceReply = nil
        reply(choice)
      }
      return
    }
    // Informational items have nothing to install; end the session
    // rather than leave the flag armed for a future attended check.
    if appcastItem.isInformationOnlyUpdate {
      endUnattendedSession()
      reply(.dismiss)
      return
    }
    reply(.install)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    guard unattended else {
      standard.showUpdateReleaseNotes(with: downloadData)
      return
    }
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
    guard unattended else {
      standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
      return
    }
  }

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    guard unattended else {
      standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
      return
    }
    endUnattendedSession()
    acknowledgement()
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    guard unattended else {
      standard.showUpdaterError(error, acknowledgement: acknowledgement)
      return
    }
    endUnattendedSession()
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    guard unattended else {
      standard.showDownloadInitiated(cancellation: cancellation)
      return
    }
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    guard unattended else {
      standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
      return
    }
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    guard unattended else {
      standard.showDownloadDidReceiveData(ofLength: length)
      return
    }
  }

  func showDownloadDidStartExtractingUpdate() {
    guard unattended else {
      standard.showDownloadDidStartExtractingUpdate()
      return
    }
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    guard unattended else {
      standard.showExtractionReceivedProgress(progress)
      return
    }
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard unattended else {
      pendingChoiceReply = reply
      standard.showReady(toInstallAndRelaunch: { [weak self] choice in
        guard let self, self.pendingChoiceReply != nil else { return }
        self.pendingChoiceReply = nil
        reply(choice)
      })
      return
    }
    reply(.install)
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {
    guard unattended else {
      standard.showInstallingUpdate(
        withApplicationTerminated: applicationTerminated,
        retryTerminatingApplication: retryTerminatingApplication
      )
      return
    }
  }

  func showUpdateInstalledAndRelaunched(
    _ relaunched: Bool,
    acknowledgement: @escaping () -> Void
  ) {
    guard unattended else {
      standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
      return
    }
    endUnattendedSession()
    acknowledgement()
  }

  func showUpdateInFocus() {
    guard unattended else {
      standard.showUpdateInFocus()
      return
    }
  }

  func dismissUpdateInstallation() {
    // Session teardown either way: any prompt Sparkle was waiting on is
    // gone with it.
    pendingChoiceReply = nil
    pendingPermissionReply = nil
    guard unattended else {
      standard.dismissUpdateInstallation()
      return
    }
    // Sparkle dismisses when aborting or finishing; either way this
    // session is over.
    endUnattendedSession()
  }
}
