import Foundation
import Sparkle

/// Sparkle user driver with no UI of its own. Codevisor renders update
/// state in Settings › Updates, so this driver only answers Sparkle's
/// prompts and forwards progress.
///
/// A session is either a check or an install. Checks started with
/// `checkForUpdateInformation` never reach the driver; a scheduled check
/// that finds a release is answered "dismiss" so the release shows up as
/// available without installing. `armInstall()` marks the current-or-next
/// session as an install: the found release, the install, and the relaunch
/// are all accepted, whether the person who asked is at this screen or at a
/// remote machine's.
@MainActor
final class HeadlessUserDriver: NSObject, SPUUserDriver {
  enum Progress {
    case downloading(fraction: Double?)
    case extracting(fraction: Double)
    case installing
  }

  var onProgress: ((Progress) -> Void)?
  private(set) var installArmed = false
  private var expectedLength: UInt64 = 0
  private var receivedLength: UInt64 = 0
  private var terminationRetry: Task<Void, Never>?

  /// Marks the current or next session as an install. Clears itself when
  /// the session ends (installed, no update, error, or dismissed).
  func armInstall() {
    installArmed = true
  }

  private func endSession() {
    installArmed = false
    expectedLength = 0
    receivedLength = 0
    terminationRetry?.cancel()
    terminationRetry = nil
  }

  // MARK: - SPUUserDriver

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

  func showUpdateFound(
    with appcastItem: SUAppcastItem,
    state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    // Informational items have nothing to install; a plain check just
    // records that a release exists (the delegate already did).
    guard installArmed, !appcastItem.isInformationOnlyUpdate else {
      reply(.dismiss)
      return
    }
    reply(.install)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    expectedLength = 0
    receivedLength = 0
    onProgress?(.downloading(fraction: nil))
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    expectedLength = expectedContentLength
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    receivedLength += length
    let fraction = expectedLength > 0 ? Double(receivedLength) / Double(expectedLength) : nil
    onProgress?(.downloading(fraction: fraction))
  }

  func showDownloadDidStartExtractingUpdate() {
    onProgress?(.extracting(fraction: 0))
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    onProgress?(.extracting(fraction: progress))
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    reply(installArmed ? .install : .dismiss)
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {
    onProgress?(.installing)
    guard !applicationTerminated else { return }
    // Sparkle asked this app to quit and it is still running (a modal
    // swallowed the request, or teardown is slow). The stock UI offers a
    // Retry button; headless, retry once on its behalf after a moment —
    // a remote machine must never sit on an installer waiting for a
    // click nobody is present to make.
    terminationRetry?.cancel()
    terminationRetry = Task { @MainActor in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      retryTerminatingApplication()
    }
  }

  func showUpdateInstalledAndRelaunched(
    _ relaunched: Bool,
    acknowledgement: @escaping () -> Void
  ) {
    endSession()
    acknowledgement()
  }

  func showUpdateInFocus() {}

  func dismissUpdateInstallation() {
    // Sparkle dismisses when aborting or finishing; either way this
    // session is over.
    endSession()
  }
}
