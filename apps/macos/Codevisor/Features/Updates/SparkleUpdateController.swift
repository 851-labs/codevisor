import CodevisorCore
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
            // An update session already showing UI keeps its UI; arming only
            // affects the session this check starts.
            if !self.updater.sessionInProgress {
                self.driver.beginUnattendedSession()
            }
            self.updater.checkForUpdates()
        }
        model.channelChangeHandler = { [weak self] _ in
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
        model.reportUpToDate()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        model.reportInstalling(
            version: item.displayVersionString,
            releasePageURL: item.infoURL ?? item.fullReleaseNotesURL ?? item.releaseNotesURL
        )
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
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
            await self.serverAgent.prepareForAppUpdate(localServer: self.localServer)
            installHandler()
        }
        return true
    }
}
