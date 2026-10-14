import Foundation
import Sparkle

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
    endSession()
  }
}
