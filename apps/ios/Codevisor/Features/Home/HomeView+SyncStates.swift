import CodevisorCore
import SwiftUI

/// The home screen's sync-state presentation: navigation visibility, the
/// native failure alert, and the refreshable surface used by loading, empty,
/// and unavailable states.
extension HomeView {
    var settingsButton: some View {
        Button {
            presentedSettingsDestination = .root
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }

    /// Machines whose last sync attempt failed — named in the alert and
    /// retried together. Fleet-aggregated: no single "selected" machine
    /// gets to speak for the others.
    var failedSyncMachines: [CodevisorMachine] {
        machines.allMachines.filter { machine in
            if case .stale = machines.navigationSyncStateByMachineId[machine.id] { return true }
            return false
        }
    }

    var failedSyncMachineIDs: Set<String> {
        Set(failedSyncMachines.map(\.id))
    }

    /// Cached records stay persisted for recovery, but Home only presents
    /// content backed by an authoritative current snapshot.
    var currentNavigationMachineIDs: Set<String> {
        Set(
            machines.allMachines.compactMap { machine in
                machines.navigationSyncStateByMachineId[machine.id] == .current
                    ? machine.id
                    : nil
            }
        )
    }

    var showsSyncFailureAlert: Bool {
        !failedSyncMachineIDs.subtracting(dismissedSyncFailureMachineIDs).isEmpty
    }

    var syncFailureAlertIsPresented: Binding<Bool> {
        Binding(
            get: { showsSyncFailureAlert },
            set: { isPresented in
                if !isPresented {
                    dismissSyncFailureAlert()
                }
            }
        )
    }

    var syncFailureAlertTitle: String {
        if let machine = failedSyncMachines.first, failedSyncMachines.count == 1 {
            return "\(machine.name) is unavailable"
        }
        return "\(failedSyncMachines.count) machines are unavailable"
    }

    var syncFailureAlertMessage: String {
        if failedSyncMachines.count == 1 {
            return "Chats from this machine are hidden until it reconnects."
        }
        return "Chats from these machines are hidden until they reconnect."
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
                await machines.prepareMachine(machine.id)
            }
        }
    }

    func dismissSyncFailureAlert() {
        dismissedSyncFailureMachineIDs.formUnion(failedSyncMachineIDs)
    }

    func openFailedMachineSettings() {
        let failed = failedSyncMachines
        dismissSyncFailureAlert()
        presentedSettingsDestination = .machines(
            focusedMachineID: failed.count == 1 ? failed[0].id : nil
        )
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
        for machine in machines.allMachines {
            await machines.refreshNavigationState(for: machine.id)
        }
    }
}
