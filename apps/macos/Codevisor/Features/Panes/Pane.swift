//  The pane abstraction for the session bottom pane group.
//
//  A pane is a self-contained content unit (terminal today; logs, previews,
//  ... later). Panes never see SessionController or the session UI — they
//  receive a PaneContext (exposed data) at creation and lifecycle hooks from
//  the group. Adding a new pane kind = a PaneKind case (CodevisorCore), a Pane
//  conformance, and a branch in the group's factory.

import Foundation
import SwiftUI
import CodevisorCore

/// The data a pane is given to do its job. The terminal pane, for example,
/// derives its working directory and server connection from here.
struct PaneContext {
    /// This pane's stable identity (persisted; survives app restarts).
    let paneId: UUID
    /// The chat session this pane group belongs to.
    let sessionId: UUID
    /// The key the server's PTY manager stores this pane's shell under.
    let terminalKey: String
    /// Agent-owned background terminal: attach to the registered terminal
    /// instead of spawning a shell (see PaneDescriptorState.attachOnly).
    let attachOnly: Bool
    /// The machine (server URL + auth) the pane's backing resources live on.
    let machine: CodevisorMachine
    /// Source data for working-directory resolution.
    let session: ChatSession
    let project: Project
}

/// Group-level commands a focused pane can emit from keyboard shortcuts
/// (⌘⌥←/→ to navigate tabs, ⌘T for a new terminal, ⌘1-9 to jump to a tab,
/// ⌘J to toggle the panel).
enum PaneGroupCommand {
    case previousTab
    case nextTab
    case newTab
    case selectTab(Int)
    case togglePanel
    case closeTab
}

/// A live pane instance. Hooks are the pane's whole world: the group tells it
/// when it becomes visible/hidden, when the user wants it focused, and when
/// it is being deleted (permanent) vs detached (app-side teardown only).
@MainActor
protocol Pane: AnyObject {
    var id: UUID { get }
    var kind: PaneKind { get }

    /// Set by the pane group: lets a focused pane forward tab-navigation
    /// shortcuts up to the group.
    var onGroupCommand: ((PaneGroupCommand) -> Void)? { get set }

    /// Set by the pane group: reports keyboard focus entering/leaving the
    /// pane's content (drives the group bar's ⌘N shortcut hints). Panes
    /// whose content doesn't track focus (the chat) never call it.
    var onFocusChanged: ((Bool) -> Void)? { get set }

    /// The pane's content view. Called when the pane is selected; the pane
    /// should cache expensive backing state (the terminal caches its NSView)
    /// so re-selection restores rather than rebuilds.
    func makeView() -> AnyView

    /// Route keyboard focus into the pane's content.
    func focus()

    /// The pane's content became visible (selected + group open) or hidden.
    func visibilityChanged(_ visible: Bool)

    /// The user is deleting this pane (closed its tab): destroy backing
    /// resources permanently (the terminal kills its server-side shell).
    func willDelete() async

    /// App-side teardown without destroying backing resources (the terminal's
    /// shell survives on the server for reattachment — app-quit semantics).
    func detach()
}
