//  The chat pane: the session's transcript + composer as a center-group tab.
//
//  The pane renders real content (ChatScreen) through the ordinary pane view
//  path. The content itself arrives via `contentProvider`, wired by the
//  session screen on mount — the chat needs the screen's SessionController
//  and focus coordinator, which panes must never own. Everything that must
//  survive tab switches (composer text, scroll position, follow mode) lives
//  on SessionController, so unmount/remount is cheap and lossless.

import Foundation
import SwiftUI
import CodevisorCore

@MainActor
@Observable
final class ChatPane: Pane {
    let id: UUID
    let kind: PaneKind = .chat
    @ObservationIgnored var onGroupCommand: ((PaneGroupCommand) -> Void)?
    /// Unused: the chat's focus lives with the composer, outside the pane.
    @ObservationIgnored var onFocusChanged: ((Bool) -> Void)?
    /// Wired by the group to the session screen's composer focus.
    @ObservationIgnored var onFocus: (() -> Void)?
    /// The chat content factory, wired by the session screen (observable so
    /// the pane host re-renders when the screen mounts and provides it).
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
