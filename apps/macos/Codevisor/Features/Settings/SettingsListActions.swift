import SwiftUI

/// The one shape every settings list's actions share: trailing-aligned
/// buttons rendered as the section footer, sitting under the list they act
/// on (the Harnesses page's Refresh / Add Custom Harness… sets the pattern).
/// An optional message — typically the last action's error — reads
/// leading-aligned above the buttons.
struct SettingsListActions<Actions: View>: View {
    var message: String?
    @ViewBuilder let actions: () -> Actions

    init(message: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                actions()
            }
        }
        // Grouped-form footers default to caption text; actions keep body size.
        .font(.body)
    }
}
