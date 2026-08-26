import CodevisorCore
import SwiftUI

/// A single-line workspace disclosure row matching project group labels. Its
/// fixed status gutter preserves alignment when expanded children own status.
struct WorkspaceDisclosureLabel: View {
    private static let statusWidth: CGFloat = 10
    private static let statusToLabelSpacing: CGFloat = 5

    let workspace: Workspace
    let status: HomeSessionStatus
    let showsStatus: Bool
    /// Fleet context: the owning machine's name, shown as a second row.
    /// Nil (single-machine fleets) keeps the compact single-line row.
    var machineName: String? = nil

    var body: some View {
        HStack(spacing: Self.statusToLabelSpacing) {
            HomeStatusIndicator(status: showsStatus ? status : .idle)
                .frame(width: Self.statusWidth)
            // The icon column centers between both text rows, like the
            // agent rows do.
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name.isEmpty ? "Workspace" : workspace.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let machineName {
                    Text(machineName)
                        .font(.footnote)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .textCase(nil)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            Self.statusWidth + Self.statusToLabelSpacing
        }
    }
}
