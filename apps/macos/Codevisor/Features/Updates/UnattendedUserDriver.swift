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

    init(hostBundle: Bundle) {
        standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
    }

    /// Arms the NEXT update session to run headless. The flag clears itself
    /// when the session ends (installed, no update, error, or dismissed), so
    /// later user-initiated checks get the standard UI again.
    func beginUnattendedSession() {
        unattended = true
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
            standard.show(request, reply: reply)
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
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
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
            standard.showReady(toInstallAndRelaunch: reply)
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
        guard unattended else {
            standard.dismissUpdateInstallation()
            return
        }
        // Sparkle dismisses when aborting or finishing; either way this
        // session is over.
        endUnattendedSession()
    }
}
