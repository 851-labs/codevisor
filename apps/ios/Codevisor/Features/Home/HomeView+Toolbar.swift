import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

// MARK: - Toolbar

extension HomeView {
  var groupReorderCancelButton: some View {
    Button("Cancel") {
      cancelGroupReorder()
    }
    .accessibilityLabel("Cancel reordering")
  }

  var groupReorderConfirmButton: some View {
    Button(role: .confirm) {
      finishGroupReorder()
    } label: {
      Image(systemName: "checkmark")
    }
    .accessibilityLabel("Finish reordering")
  }

  /// Organization controls grouping; ordering applies only to agent rows.
  var organizeMenu: some View {
    Menu {
      Picker("Organization", selection: $organizationRaw) {
        ForEach(HomeOrganization.allCases, id: \.rawValue) { organization in
          Text(organization.title).tag(organization.rawValue)
        }
      }
      .pickerStyle(.menu)
      Picker("Order agents by", selection: $orderRaw) {
        ForEach(HomeOrder.allCases, id: \.rawValue) { order in
          Text(order.title).tag(order.rawValue)
        }
      }
      .pickerStyle(.menu)
      switch organization {
      case .compact:
        EmptyView()
      case .byWorkspace:
        Divider()
        Toggle("Show empty workspaces", isOn: $showEmptyWorkspaces)
        Toggle(
          "Reorder workspaces",
          isOn: groupReorderBinding(for: .byWorkspace)
        )
      case .byProject:
        Divider()
        Toggle("Show empty projects", isOn: $showEmptyProjects)
        Toggle(
          "Reorder projects",
          isOn: groupReorderBinding(for: .byProject)
        )
      }
      if order == .none {
        Button("Reset agents order") { manualSessionOrder = "" }
      }
    } label: {
      Image(systemName: "line.3.horizontal.decrease")
    }
    .accessibilityLabel("Organize list")
  }

  var newChatButton: some View {
    Button {
      presentNewChat()
    } label: {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 18, weight: .semibold))
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .matchedTransitionSource(
      id: Self.newChatTransitionID,
      in: newChatTransition
    )
    .padding(.trailing, 16)
    .padding(.bottom, 8)
    .accessibilityLabel("New chat")
  }
}
