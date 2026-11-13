import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarSelectionHistory: ViewModifier {
  @Binding var selection: SidebarSelection?
  let revealRequest: SidebarRevealRequest
  @Environment(AppEnvironment.self) private var environment
  @State private var history = SidebarHistory<RememberedSidebarSelection>()

  private var plan: SidebarRestorePlan { SidebarRestorePlan(environment: environment) }

  func body(content: Content) -> some View {
    content
      .onChange(of: selection, initial: true) { _, next in record(next) }
      .focusedSceneValue(\.sidebarHistory, actions)
      .environment(\.sidebarHistory, actions)
  }

  private var actions: SidebarHistoryActions {
    SidebarHistoryActions(
      canGoBack: history.canGoBack(where: canReopen),
      canGoForward: history.canGoForward(where: canReopen),
      goBack: { reopen(history.goBack(where: canReopen)) },
      goForward: { reopen(history.goForward(where: canReopen)) }
    )
  }

  private func record(_ selection: SidebarSelection?) {
    guard let selection, selection.owningMode != nil else {
      history.leave()
      return
    }

    history.visit(plan.remembering(selection))
  }

  private func canReopen(_ entry: RememberedSidebarSelection) -> Bool {
    target(of: entry) != nil
  }

  private func reopen(_ entry: RememberedSidebarSelection?) {
    guard let entry, let target = target(of: entry) else { return }

    revealRequest.rowID = entry.workspaceId
    selection = target
  }

  private func target(of entry: RememberedSidebarSelection) -> SidebarSelection? {
    plan.reopening(entry)
  }
}
