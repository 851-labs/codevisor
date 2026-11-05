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
              .padding(.horizontal, 10)
          }
          subview
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
      }
    }
    .labeledContentStyle(WorkspaceInspectorLabeledContentStyle())
    .labelStyle(WorkspaceInspectorLabelStyle())
  }
}
