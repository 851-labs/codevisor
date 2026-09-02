import UIKit

/// New Chat's ordinary composer owns an ordinary local UITextView. The
/// registry remembers only weak source/destination ports until Send explicitly
/// begins promotion; only then does one entry temporarily own the concrete
/// first responder. This distinction is what makes dismiss/reopen safe: draft
/// data survives in SessionController, while UIKit presentation state does not.
@MainActor
enum ComposerTextViewHandoffRegistry {
  private final class Ports {
    weak var source: ComposerTextViewContainer?
    weak var destination: ComposerTextViewContainer?
  }

  private final class Entry {
    let editor: HeightReportingTextView
    weak var owner: ComposerTextViewContainer?
    var ownerRole: ComposerTextEditorHandoffRole
    weak var pendingDestination: ComposerTextViewContainer?
    var parkedAlpha: CGFloat?
    var isPortaled = false

    init(
      editor: HeightReportingTextView,
      owner: ComposerTextViewContainer,
      role: ComposerTextEditorHandoffRole
    ) {
      self.editor = editor
      self.owner = owner
      ownerRole = role
    }
  }

  private static var ports: [UUID: Ports] = [:]
  private static var entries: [UUID: Entry] = [:]

  static func attachSource(
    id: UUID,
    to container: ComposerTextViewContainer,
    makeEditor: () -> HeightReportingTextView
  ) -> HeightReportingTextView? {
    // Once Send has transferred this editor into window space, a source
    // reconciliation must not create a replacement underneath the opaque
    // transition surface or steal the responder back from its destination.
    guard entries[id] == nil else { return nil }

    let port = ports[id] ?? Ports()
    port.source = container
    ports[id] = port

    let editor = container.localEditor ?? makeEditor()
    container.localEditor = editor
    if editor.superview !== container {
      container.addSubview(editor)
    }
    editor.frame = container.bounds
    return editor
  }

  static func attachDestination(
    id: UUID,
    to container: ComposerTextViewContainer
  ) -> HeightReportingTextView? {
    let port = ports[id] ?? Ports()
    port.destination = container
    ports[id] = port

    guard let entry = entries[id] else { return nil }
    if entry.ownerRole == .promotionSource {
      entry.pendingDestination = container
      return nil
    }
    entry.owner = container
    place(entry, through: container)
    return entry.editor
  }

  static func release(_ container: ComposerTextViewContainer) {
    var emptyPortIDs: [UUID] = []
    for (id, port) in ports {
      if port.source === container { port.source = nil }
      if port.destination === container { port.destination = nil }
      if port.source == nil, port.destination == nil, entries[id] == nil {
        emptyPortIDs.append(id)
      }
    }
    for id in emptyPortIDs { ports.removeValue(forKey: id) }

    guard let match = entries.first(where: { $0.value.owner === container }) else {
      container.localEditor?.removeFromSuperview()
      container.localEditor = nil
      return
    }
    // Dismantling the modal's source port is the authoritative ownership
    // boundary. The real workspace registered its destination port before
    // dismissal, so transfer geometry/delegate ownership without ever
    // removing the active editor from its stable UIWindow superview.
    if let destination = match.value.pendingDestination,
      destination.window != nil
    {
      place(match.value, through: destination)
      match.value.owner = destination
      match.value.ownerRole = .promotionDestination
      match.value.pendingDestination = nil
      destination.activateIfPossible()
      return
    }
    // A normal composer teardown has no successor and retires its editor.
    match.value.editor.alpha = match.value.parkedAlpha ?? match.value.editor.alpha
    match.value.editor.removeFromSuperview()
    entries.removeValue(forKey: match.key)
    ports.removeValue(forKey: match.key)
    container.localEditor = nil
  }

  /// Explicit terminal cleanup for a native sheet that closed without
  /// sending. Normally there is no active entry at all; this also makes a
  /// cancelled/failed partial handoff idempotently safe.
  static func cancel(_ id: UUID) {
    if let entry = entries.removeValue(forKey: id) {
      entry.editor.alpha = entry.parkedAlpha ?? entry.editor.alpha
      entry.parkedAlpha = nil
      entry.isPortaled = false
      entry.editor.removeFromSuperview()
    }
    ports.removeValue(forKey: id)
  }

  /// Promotion state is transient; its destination view is not. Convert the
  /// registry-owned editor into that same container's ordinary local editor
  /// without changing object identity, focus, or responder chain.
  static func retirePromotionEditor(
    ownedBy container: ComposerTextViewContainer
  ) -> HeightReportingTextView? {
    guard let match = entries.first(where: { $0.value.owner === container }) else {
      return nil
    }
    entries.removeValue(forKey: match.key)
    ports.removeValue(forKey: match.key)
    match.value.pendingDestination = nil
    match.value.editor.alpha = match.value.parkedAlpha ?? match.value.editor.alpha
    match.value.parkedAlpha = nil
    match.value.isPortaled = false
    return match.value.editor
  }

  /// Ends the window portal synchronously at the structural commit. Waiting
  /// for SwiftUI's next representable update leaves a real, interactive text
  /// view above the entire app for at least one reconciliation; a fast tab
  /// change can then expose it over non-chat content. Reparenting the same
  /// responder within the same UIWindow preserves identity while restoring
  /// ordinary ancestor clipping and visibility immediately.
  @discardableResult
  static func settlePromotedEditor(id: UUID) -> Bool {
    guard let entry = entries[id],
      entry.ownerRole == .promotionDestination
        || entry.pendingDestination?.window != nil
    else { return false }

    if entry.ownerRole == .promotionSource,
      let destination = entry.pendingDestination
    {
      entry.owner = destination
      entry.ownerRole = .promotionDestination
    }
    guard let owner = entry.owner else { return false }

    let editor = entry.editor
    entries.removeValue(forKey: id)
    ports.removeValue(forKey: id)
    entry.pendingDestination = nil
    editor.alpha = entry.parkedAlpha ?? editor.alpha
    entry.parkedAlpha = nil
    entry.isPortaled = false
    owner.localEditor = editor
    if editor.superview !== owner {
      owner.addSubview(editor)
    }
    editor.frame = owner.bounds
    owner.setNeedsLayout()
    return editor.superview === owner
  }

  static func layoutEditor(ownedBy container: ComposerTextViewContainer) {
    guard
      let entry = entries.values.first(where: {
        $0.owner === container && $0.isPortaled
      })
    else { return }
    portal(entry, through: container)
  }

  private static func place(
    _ entry: Entry,
    through container: ComposerTextViewContainer
  ) {
    if entry.isPortaled {
      portal(entry, through: container)
    } else {
      contain(entry, in: container)
    }
  }

  /// Ordinary composition stays inside the SwiftUI-owned container so every
  /// native sheet transform, clip, and dismissal gesture applies to the
  /// editor exactly as it does to the rest of the composer.
  private static func contain(
    _ entry: Entry,
    in container: ComposerTextViewContainer
  ) {
    entry.isPortaled = false
    if entry.editor.superview !== container {
      container.addSubview(entry.editor)
    }
    entry.editor.frame = container.bounds
  }

  /// Promotion editors live directly in their one app window only for the
  /// sheet-to-route morph. The settled canonical workspace changes to role
  /// `.none`, and `retirePromotionEditor` immediately returns this exact view
  /// to its composer container before any other pane can become visible.
  private static func portal(_ entry: Entry, through container: ComposerTextViewContainer) {
    guard let window = container.window else { return }
    entry.isPortaled = true
    if entry.editor.superview !== window {
      window.addSubview(entry.editor)
    } else {
      window.bringSubviewToFront(entry.editor)
    }
    entry.editor.frame = container.convert(container.bounds, to: window)
  }

  /// The transition snapshot and message-flight view become the sole visual
  /// owners of the draft while the real editor keeps the keyboard session
  /// alive underneath them. Alpha does not alter responder ownership or the
  /// editor's UIWindow ancestry.
  static func beginStablePortalTransition(id: UUID) -> Bool {
    guard entries[id] == nil,
      let port = ports[id],
      let owner = port.source,
      let editor = owner.localEditor,
      owner.window != nil
    else { return false }
    let entry = Entry(editor: editor, owner: owner, role: .promotionSource)
    entry.pendingDestination = port.destination
    entries[id] = entry
    // Ownership changes only now. Before Send, the editor was an ordinary
    // child of the ordinary sheet composer and could be freely destroyed.
    owner.localEditor = nil
    // Reparent the existing first responder within the same UIWindow at
    // the last possible moment. Before this call it remains a normal sheet
    // descendant; after it, its stable window ancestry survives the
    // sheet-to-route structural swap without retracting the keyboard.
    portal(entry, through: owner)
    if entry.parkedAlpha == nil {
      entry.parkedAlpha = entry.editor.alpha
    }
    entry.editor.alpha = 0.001
    return entry.editor.isFirstResponder
  }

  static func promotedEditor(id: UUID) -> UIView? {
    entries[id]?.ownerRole == .promotionDestination
      ? entries[id]?.editor
      : nil
  }

  /// Change only logical owner, bindings, and window-space frame. The
  /// concrete UITextView stays in the same UIWindow and remains the same
  /// first responder, so UIKit has no reason to end the keyboard session.
  static func completeStablePortalHandoff(id: UUID) -> Bool {
    guard let entry = entries[id],
      entry.ownerRole == .promotionSource,
      entry.pendingDestination?.window != nil,
      let destination = entry.pendingDestination
    else { return false }
    entry.owner = destination
    entry.ownerRole = .promotionDestination
    entry.pendingDestination = nil
    destination.activateIfPossible()
    portal(entry, through: destination)
    entry.editor.alpha = entry.parkedAlpha ?? 1
    entry.parkedAlpha = nil
    return entry.editor.isFirstResponder
  }
}
