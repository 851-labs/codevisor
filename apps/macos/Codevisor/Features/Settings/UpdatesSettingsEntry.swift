import CodevisorCore
import CodevisorUI
import SwiftUI

/// The Settings ▸ General row that opens the update center, with an
/// at-a-glance count of everything updatable across the fleet.
struct UpdatesSettingsEntry: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    var body: some View {
        LabeledContent {
            Button("View Updates…") {
                environment.updateCenter.isPresented = true
            }
            .settingsActionTint(theme)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Updates")
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        switch environment.updateCenter.availableCount {
        case 0: "Everything is up to date."
        case 1: "1 update available."
        case let count: "\(count) updates available."
        }
    }
}
