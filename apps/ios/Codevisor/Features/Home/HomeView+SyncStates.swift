import CodevisorCore
import SwiftUI

/// The home screen's sync-state chrome, split from HomeView for the size
/// ratchet: the non-blocking failure banner and the refreshable scroll
/// wrapper the loading/empty/unavailable states render inside.
extension HomeView {
    /// Machines whose last sync attempt failed — named in the banner and
    /// retried together. Fleet-aggregated: no single "selected" machine
    /// gets to speak for the others.
    var failedSyncMachines: [CodevisorMachine] {
        machines.allMachines.filter { machine in
            if case .stale = machines.navigationSyncStateByMachineId[machine.id] { return true }
            return false
        }
    }

    /// True once ANY machine has completed a sync this launch — enough to
    /// honestly claim "there are no chats" instead of "still loading".
    var anyMachineSynced: Bool {
        machines.allMachines.contains { machine in
            machines.navigationSyncStateByMachineId[machine.id] == .current
        }
    }

    /// The machines that failed, named — "your machines" while none have.
    var failedSyncMachineNames: String {
        let names = failedSyncMachines.map(\.name)
        return names.isEmpty ? "your machines" : names.joined(separator: ", ")
    }

    /// Reconnects every machine whose sync failed — retry addresses the
    /// machines that actually broke, not a "selected" one.
    func retryFailedMachines() {
        let failed = failedSyncMachines
        Task {
            for machine in failed {
                await machines.connectMachine(machine.id)
            }
            await machines.refreshSelectedNavigationState()
        }
    }

    /// Compact, non-blocking: the list stays usable while machines that
    /// couldn't sync announce themselves and offer retry.
    var syncFailedBanner: some View {
        HStack(spacing: 10) {
            Label(
                "Couldn't sync with \(failedSyncMachineNames)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .lineLimit(2)
            Spacer(minLength: 8)
            Button("Retry") {
                retryFailedMachines()
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// Keep state content fixed over the same native list surface used when
    /// rows exist. The list owns refresh and rubber-band scrolling; the
    /// overlay stays centered in the visible viewport instead of moving with
    /// the scroll content.
    func refreshableState<Content: View>(
        allowsStateHitTesting: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        List {
            EmptyView()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .refreshable {
            await refreshNavigation()
        }
        .overlay {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(allowsStateHitTesting)
        }
    }

    func refreshNavigation() async {
        await machines.refreshSelectedNavigationState()
    }
}
