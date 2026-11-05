import SwiftUI

struct WorkspaceInspectorCardRows<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Group(subviews: content) { subviews in
        ForEach(subviews) { subview in
          if subview.id != subviews.first?.id {
            Rectangle()
              .fill(Color.primary.opacity(0.05))
              .frame(height: 1)
              .padding(.horizontal, WorkspaceInspectorCardShape.rowPadding)
          }
          subview
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding(for: subview))
            .environment(\.workspaceInspectorCardRowShape, shape(for: subview, in: subviews))
        }
      }
    }
    .labeledContentStyle(WorkspaceInspectorLabeledContentStyle())
    .labelStyle(WorkspaceInspectorLabelStyle())
  }

  private func shape(for subview: Subview, in subviews: SubviewsCollection) -> UnevenRoundedRectangle {
    WorkspaceInspectorCardShape.row(isFirst: subview.id == subviews.first?.id, isLast: subview.id == subviews.last?.id)
  }

  private func padding(for subview: Subview) -> CGFloat {
    subview.containerValues.fillsWorkspaceInspectorCardRow ? 0 : WorkspaceInspectorCardShape.rowPadding
  }
}
