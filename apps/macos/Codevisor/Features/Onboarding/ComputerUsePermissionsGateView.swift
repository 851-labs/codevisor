import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI

/// The Computer Use permissions checklist: one row per system permission the
/// app requests, with live status. Status probes are cheap and non-prompting,
/// so the view polls once a second and re-checks on window activation — the
/// row flips to Granted almost instantly after a System Settings round trip.
struct ComputerUsePermissionRowsView: View {
    let model: ComputerUsePermissionsModel
    /// Embedded rows sit inside an existing container (a settings form row)
    /// and skip the standalone card chrome.
    var embedded = false
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(alignment: .leading, spacing: embedded ? 0 : 12) {
            if embedded {
                rows
            } else {
                rows
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
            }

            if model.screenRecordingGrantedThisRun {
                relaunchNudge
                    .padding(.top, embedded ? 8 : 0)
            }
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: controlActiveState) { _, _ in
            model.refresh()
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            permissionRow(
                symbol: "accessibility",
                title: "Accessibility",
                subtitle: "Reads on-screen text and controls",
                granted: model.isAccessibilityGranted
            ) {
                model.requestAccessibility()
            }
            Divider()
            permissionRow(
                symbol: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                subtitle: "Sees app windows",
                granted: model.isScreenRecordingGranted
            ) {
                model.requestScreenRecording()
            }
        }
    }

    private func permissionRow(
        symbol: String,
        title: String,
        subtitle: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: embedded ? 14 : 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: embedded ? 26 : 34, height: embedded ? 26 : 34)
                .background(RoundedRectangle(cornerRadius: embedded ? 6 : 8).fill(theme.cardHoverBackground))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.statusOK)
                    .labelStyle(.titleAndIcon)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Button("Allow…", action: action)
                    .controlSize(embedded ? .small : .regular)
            }
        }
        .padding(.vertical, embedded ? 7 : 10)
        .animation(.smooth(duration: 0.25), value: granted)
    }

    /// macOS applies a fresh Screen Recording grant fully only to new
    /// processes; a running app can keep getting empty captures. Offer the
    /// restart instead of letting the first Computer Use task fail oddly.
    private var relaunchNudge: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Screen Recording applies after Codevisor restarts")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Restart Now") { AppRelauncher.relaunch() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Update gate for already-onboarded users, presented as a dialog card over
/// the main window: shown once per app version at launch when the Computer
/// Use permissions are missing (for example right after updating to the first
/// build that needs them). Skipping turns Computer Use off; the toggle in
/// Settings → MCP re-enters this setup inline.
///
/// Deliberately not an AppKit sheet: a document-modal sheet refuses app
/// termination (macOS beeps and cancels), and granting Screen Recording ends
/// in macOS's own "Quit & Reopen" — which has to be able to quit us.
struct ComputerUsePermissionsGateView: View {
    var onComplete: () -> Void
    var onSkip: () -> Void

    @Environment(\.theme) private var theme
    @State private var model = ComputerUsePermissionsModel(
        probes: AppPreview.isRunning ? .granted : .live
    )

    var body: some View {
        ZStack {
            // Absorbs clicks to the app underneath without entering a modal
            // session, so the dialog still reads as blocking.
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {}

            card
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 5)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Allow Computer Use")
                    .font(.title2.bold())
                Text("Codevisor uses these to operate apps when you ask.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ComputerUsePermissionRowsView(model: model)

            HStack {
                Button("Set Up Later") { onSkip() }
                Spacer()
                Button("Continue") { onComplete() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.allGranted)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.isSystem ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(theme.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.32), radius: 26, y: 12)
    }
}

#Preview("Permissions gate") {
    ComputerUsePermissionsGateView(onComplete: {}, onSkip: {})
        .frame(width: 900, height: 640)
}
