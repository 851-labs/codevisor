import CodevisorCore
import SwiftUI

/// The app-update and remote-server-update banners pinned above the sidebar
/// list. At most one shows at a time.
struct SidebarUpdateBanners: View {
    let environment: AppEnvironment
    let store: SessionStore?
    let skippedUpdateVersion: String
    let skippedServerUpdate: String

    var body: some View {
        if let release = environment.appUpdate.availableRelease,
            release.version != skippedUpdateVersion
        {
            UpdateBannerView(
                model: environment.appUpdate,
                release: release,
                hasRunningChats: store?.hasActiveSessions(onServer: CodevisorMachine.local.id) ?? false
            )
            .padding(8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        // The selected remote machine's server has a newer release. (For
        // the local machine the app banner above covers app + server.)
        // Gated behind the local app being current: the user updates their
        // own machine before pushing updates to a remote one, so the two
        // banners are never shown at the same time.
        if environment.appUpdate.availableRelease == nil,
            let serverUpdate = environment.machines.selectedServerUpdate,
            serverUpdate.updateAvailable,
            !environment.machines.selectedMachine.isLocal,
            skippedServerUpdate != serverUpdateSkipKey(serverUpdate)
        {
            ServerUpdateBannerView(
                machines: environment.machines,
                machine: environment.machines.selectedMachine,
                update: serverUpdate,
                hasRunningChats: store?.hasActiveSessions(onServer: environment.machines.selectedMachineId) ?? false
            )
            .padding(8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// One skip entry per machine + version, so dismissing one machine's
    /// server update doesn't hide another's.
    private func serverUpdateSkipKey(_ update: ServerUpdateInfo) -> String {
        "\(environment.machines.selectedMachineId):\(update.latestVersion)"
    }
}
