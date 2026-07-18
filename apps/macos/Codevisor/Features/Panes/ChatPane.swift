//  The chat pane: the session's transcript + composer as a center-group tab.
//
//  Deliberately a shell. The chat content is owned and rendered by
//  SessionScreen (it needs SessionController, focus plumbing, and streaming
//  state that panes must never see), and it stays mounted across tab switches
//  so the transcript's scroll/streaming machinery is never torn down. This
//  object only gives the chat a seat at the pane-group table: identity,
//  selection, and focus routing.

import Foundation
import SwiftUI
import CodevisorCore

@MainActor
final class ChatPane: Pane {
    let id: UUID
    let kind: PaneKind = .chat
    var onGroupCommand: ((PaneGroupCommand) -> Void)?
    /// Unused: the chat's focus lives with the composer, outside the pane.
    var onFocusChanged: ((Bool) -> Void)?
    /// Wired by the group to the session screen's composer focus.
    var onFocus: (() -> Void)?

    init(id: UUID) {
        self.id = id
    }

    /// Never rendered: SessionScreen shows the chat content itself (kept
    /// alive across tab switches) instead of going through the pane view.
    func makeView() -> AnyView {
        AnyView(EmptyView())
    }

    func focus() {
        onFocus?()
    }

    func visibilityChanged(_ visible: Bool) {}

    func willDelete() async {}

    func detach() {}
}
