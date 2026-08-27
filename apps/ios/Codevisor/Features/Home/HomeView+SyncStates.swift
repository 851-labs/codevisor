import CodevisorCore
import SwiftUI

/// The home screen's sync-state chrome, split from HomeView for the size
/// ratchet: the non-blocking failure banner and the refreshable scroll
/// wrapper the loading/empty/unavailable states render inside.
extension HomeView {
    /// Compact, non-blocking: the list stays usable while a machine that
    /// couldn't sync announces itself and offers retry.
    var syncFailedBanner: some View {
        HStack(spacing: 10) {
            Label(
                "Couldn't sync with \(machines.selectedMachine.name)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .lineLimit(2)
            Spacer(minLength: 8)
            Button("Retry") {
                Task { await machines.retrySelectedMachine() }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// A full-height native scroll surface preserves centered state content
    /// while allowing the standard iOS pull-to-refresh gesture even when
    /// there are no rows to make the content scroll naturally.
    func refreshableState<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                // Exactly the visible height: the state stays centered and
                // the only scroll left is the rubber-band pull-to-refresh
                // needs — no phantom scrolling past an empty page.
                .containerRelativeFrame(.vertical)
        }
        .refreshable {
            await refreshNavigation()
        }
    }

    func refreshNavigation() async {
        await machines.refreshSelectedNavigationState()
    }
}
