import CodevisorCore
import Foundation
import Sparkle

/// Owns Sparkle for the lifetime of the app and adapts its native updater to
/// the small observable model used by Codevisor's sidebar.
@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate {
    private let model: AppUpdateModel
    private weak var localServer: LocalCodevisorServer?
    private let serverAgent: MacServerAgentController
    private var controller: SPUStandardUpdaterController!

    init(
        model: AppUpdateModel,
        localServer: LocalCodevisorServer?,
        serverAgent: MacServerAgentController
    ) {
        self.model = model
        self.localServer = localServer
        self.serverAgent = serverAgent
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        model.checkHandler = { [weak self] userInitiated in
            guard let self else { return }
            if userInitiated {
                self.controller.checkForUpdates(nil)
            } else {
                self.controller.updater.checkForUpdateInformation()
            }
        }
        model.installHandler = { [weak self] _ in
            self?.controller.checkForUpdates(nil)
        }
        model.channelChangeHandler = { [weak self] _ in
            self?.controller.updater.resetUpdateCycle()
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        model.allowsAlphaUpdates ? ["alpha"] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        #if arch(x86_64)
            "https://updates.codevisor.dev/appcast-x64.xml"
        #else
            "https://updates.codevisor.dev/appcast-arm64.xml"
        #endif
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        model.reportAvailable(
            version: item.displayVersionString,
            releasePageURL: item.releaseNotesURL ?? item.infoURL
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        model.reportUpToDate()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        model.reportInstalling(
            version: item.displayVersionString,
            releasePageURL: item.releaseNotesURL ?? item.infoURL
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
