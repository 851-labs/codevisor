import SwiftUI

/// How a machine's slice of a config plane is doing, shown on its
/// disclosure row: converging, settled, or waiting on the user.
enum MachineSyncBadge {
    case syncing
    case synced
    case attention(String)

    @ViewBuilder
    var view: some View {
        switch self {
        case .syncing:
            HStack(spacing: 5) {
                ProgressView()
                Text("Syncing…")
            }
            .foregroundStyle(.secondary)
        case .synced:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Synced")
                    .foregroundStyle(.secondary)
            }
        case .attention(let label):
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(label)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
