import CodevisorCore
import CodevisorCoreMac
import Foundation
import Sparkle

/// Owns Sparkle for the lifetime of the app and adapts its native updater to
/// the small observable model used by Codevisor's sidebar.
@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate {
    private let model: AppUpdateModel
    private weak var localServer: (any LocalServerControlling)?
    private let serverAgent: MacServerAgentController
    private var updater: SPUUpdater!
    private var driver: UnattendedUserDriver!
    /// True from a remote-triggered (headless) session's arming until it
    /// reports an outcome. Guards the handoff status writes so attended
    /// flows never touch the file a remote client is polling through the
    /// server.
    private var unattendedSessionActive = false

    init(
        model: AppUpdateModel,
        localServer: (any LocalServerControlling)?,
        serverAgent: MacServerAgentController
    ) {
        self.model = model
        self.localServer = localServer
        self.serverAgent = serverAgent
        super.init()
        // A raw SPUUpdater with our own driver instead of
        // SPUStandardUpdaterController: attended flows still get Sparkle's
        // stock UI (the driver forwards to SPUStandardUserDriver), while
        // remote-triggered updates run a fully headless session — the
        // machine being updated may have nobody at its screen to accept a
        // prompt.
        driver = UnattendedUserDriver(hostBundle: .main)
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: self
        )
        do {
            try updater.start()
        } catch {
            model.reportFailure(error.localizedDescription)
        }
        // A fresh boot is the success path of an unattended install (the
        // relaunched app IS the update): drop any stale handoff report, and
        // re-assert this machine's release channel for the bundled server —
        // it answers /v1/update from this preference, never a client's.
        AppUpdateHandoff.clearStatus()
        AppUpdateHandoff.writeChannel(allowsAlpha: model.allowsAlphaUpdates)
        model.checkHandler = { [weak self] userInitiated in
            guard let self else { return }
            if userInitiated {
                self.updater.checkForUpdates()
            } else {
                self.updater.checkForUpdateInformation()
            }
        }
        model.installHandler = { [weak self] _ in
            self?.updater.checkForUpdates()
        }
        model.unattendedInstallHandler = { [weak self] in
            guard let self else { return }
            // Arm even when a session is already in progress: a background
            // check may have found this update and parked an attended
            // prompt on this machine's screen before the remote request
            // arrived. The driver answers that prompt and dismisses its UI
            // — a remote machine must never wait on a click nobody is
            // present to make.
            self.unattendedSessionActive = true
            AppUpdateHandoff.writeStatus(state: "installing")
            self.driver.beginUnattendedSession()
            if !self.updater.sessionInProgress {
                self.updater.checkForUpdates()
            }
        }
        model.channelChangeHandler = { [weak self] allowsAlpha in
            // The bundled server answers /v1/update from this machine's own
            // channel; keep its copy of the preference current.
            AppUpdateHandoff.writeChannel(allowsAlpha: allowsAlpha)
            self?.updater.resetUpdateCycle()
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        model.allowsAlphaUpdates ? ["alpha"] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        if let developmentFeedURL = CodevisorAppVariant.developmentSparkleFeedURL {
            return developmentFeedURL
        }
        #if arch(x86_64)
            return "https://updates.codevisor.dev/appcast-x64.xml"
        #else
            return "https://updates.codevisor.dev/appcast-arm64.xml"
        #endif
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        model.reportAvailable(
            version: item.displayVersionString,
            releasePageURL: item.infoURL ?? item.fullReleaseNotesURL ?? item.releaseNotesURL
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if unattendedSessionActive {
            unattendedSessionActive = false
            // The server's manifest said "newer" but this machine's Sparkle
            // feed disagrees (usually a channel mismatch). Report it so the
            // remote client fails fast instead of polling to a timeout.
            AppUpdateHandoff.writeStatus(
                state: "failed",
                message:
                    "This machine's update feed has no newer release. Check its Alpha updates setting."
            )
        }
        model.reportUpToDate()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        if unattendedSessionActive {
            AppUpdateHandoff.writeStatus(
                state: "installing",
                targetVersion: item.displayVersionString
            )
        }
        model.reportInstalling(
            version: item.displayVersionString,
            releasePageURL: item.infoURL ?? item.fullReleaseNotesURL ?? item.releaseNotesURL
        )
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if unattendedSessionActive {
            unattendedSessionActive = false
            AppUpdateHandoff.writeStatus(state: "failed", message: error.localizedDescription)
        }
        // "No update" is reported through updaterDidNotFindUpdate. Keep
        // dismissing or skipping an update non-error state in our own UI.
        if case .checking = model.phase {
            model.reportFailure(error.localizedDescription)
        } else if model.isUpdating {
            model.reportFailure(error.localizedDescription)
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        Task { @MainActor [weak self] in
            guard let self else {
                installHandler()
                return
            }
            guard await self.serverAgent.prepareForAppUpdate(localServer: self.localServer) else {
                if self.unattendedSessionActive {
                    self.unattendedSessionActive = false
                    AppUpdateHandoff.writeStatus(
                        state: "failed",
                        message: "The Codevisor server could not be stopped safely for the update."
                    )
                }
                self.model.reportFailure(
                    "The Codevisor server could not be stopped safely. Restart Codevisor and try the update again."
                )
                return
            }
            installHandler()
        }
        return true
    }
}
