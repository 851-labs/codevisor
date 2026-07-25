import SwiftUI
import CodevisorCore

/// A transparent notice after an opted-in run crashes.
struct DiagnosticsBannerLayer: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    var diagnostics: DiagnosticsClient = .shared

    private static let privacyURL = URL(string: "https://www.codevisor.dev/privacy#diagnostics")!

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Spacer()

            if diagnostics.crashedLastRun {
                card(systemImage: "exclamationmark.triangle", title: "Codevisor closed unexpectedly") {
                    Text("A privacy-filtered diagnostic report was queued because crash reporting is on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack {
                        Link("Details", destination: Self.privacyURL)
                        Spacer()
                        Button("Turn Off") {
                            environment.setShareCrashReports(false)
                            diagnostics.dismissCrashNotice()
                        }
                        Button("Dismiss") {
                            diagnostics.dismissCrashNotice()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.snappy(duration: 0.25), value: diagnostics.crashedLastRun)
        .allowsHitTesting(diagnostics.crashedLastRun)
    }

    private func card<Content: View>(
        systemImage: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(theme.statusWarn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.callout.weight(.semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 390, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }
}
