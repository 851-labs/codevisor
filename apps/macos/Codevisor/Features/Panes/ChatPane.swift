import Foundation
import SwiftUI
import CodevisorCore

@MainActor
@Observable
final class ChatPane: Pane {
  let id: UUID
  let kind: PaneKind = .chat
  @ObservationIgnored var onGroupCommand: ((PaneGroupCommand) -> Void)?
  @ObservationIgnored var onFocusChanged: ((Bool) -> Void)?
  @ObservationIgnored var onFocus: (() -> Void)?
  var contentProvider: (() -> AnyView)?

  init(id: UUID) {
    self.id = id
  }

  func makeView() -> AnyView {
    contentProvider?() ?? AnyView(EmptyView())
  }

  func focus() {
    onFocus?()
  }

  func visibilityChanged(_ visible: Bool) {}

  func willDelete() async {}

  func detach() {}
}
