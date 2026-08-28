import AppKit
import CodevisorCore
import SwiftUI

/// Hosts the update center sheet and the fleet upkeep cadence. Its own
/// modifier (like the deeplink handlers) so ContentView's already-large
/// chain stays within type-checker and size budgets.
struct UpdateCenterPresentation: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Bindable(environment.updateCenter).isPresented) {
                UpdateCenterView()
                    .background(UpdateCenterTerminationPermit())
            }
            .task {
                // Fleet-wide upkeep, deliberately NOT keyed to the selected
                // machine: every machine keeps its stream and release state
                // current, so a release cut (or work finishing) on an
                // unselected machine is still noticed. One initial sweep
                // populates the sidebar footer's count, then the cadence.
                guard !AppPreview.isRunning else { return }
                // A pending update-all session (the app update restarted
                // this client, or a run died) reopens the surface first.
                await environment.updateCenter.resumePendingSessionIfNeeded()
                await environment.updateCenter.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5 * 60))
                    guard !Task.isCancelled else { return }
                    environment.machines.ensureBackgroundConnections()
                    await environment.machines.refreshServerUpdates()
                    await environment.updateCenter.refresh()
                    await environment.configSync.synchronizeAll()
                }
            }
    }
}

/// Lets Sparkle's normal quit request close the app while the Update Center
/// sheet is open. AppKit otherwise rejects termination whenever a modal sheet
/// is attached, leaving Sparkle's installer waiting for this process to exit.
private struct UpdateCenterTerminationPermit: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowProbe()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.preventsApplicationTerminationWhenModal = false
    }

    private final class WindowProbe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.preventsApplicationTerminationWhenModal = false
        }
    }
}
