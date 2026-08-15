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

    var body: some View {
        HStack(spacing: Self.statusToLabelSpacing) {
            HomeStatusIndicator(status: showsStatus ? status : .idle)
                .frame(width: Self.statusWidth)
            Label(
                workspace.name.isEmpty ? "Workspace" : workspace.name,
                systemImage: "square.grid.2x2"
            )
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            Self.statusWidth + Self.statusToLabelSpacing
        }
    }
}
