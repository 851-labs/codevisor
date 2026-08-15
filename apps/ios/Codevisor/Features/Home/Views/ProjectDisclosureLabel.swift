import CodevisorCore
import SwiftUI

/// Native disclosure label for a project and its direct agent children.
struct ProjectDisclosureLabel: View {
    private static let statusWidth: CGFloat = 10
    private static let statusToLabelSpacing: CGFloat = 5

    let project: Project
    let status: HomeSessionStatus
    let showsStatus: Bool

    private var symbolName: String {
        project.symbolName == Project.defaultSymbolName ? "folder" : project.symbolName
    }

    var body: some View {
        HStack(spacing: Self.statusToLabelSpacing) {
            HomeStatusIndicator(status: showsStatus ? status : .idle)
                .frame(width: Self.statusWidth)
            Label(project.name, systemImage: symbolName)
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
