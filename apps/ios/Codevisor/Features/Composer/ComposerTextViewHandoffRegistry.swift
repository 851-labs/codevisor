import UIKit

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

  static func isEditorFocused(id: UUID) -> Bool? {
    if let entry = entries[id] { return entry.editor.isFirstResponder }
    return ports[id]?.source?.localEditor?.isFirstResponder
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
    match.value.editor.alpha = match.value.parkedAlpha ?? match.value.editor.alpha
    match.value.editor.removeFromSuperview()
    entries.removeValue(forKey: match.key)
    ports.removeValue(forKey: match.key)
    container.localEditor = nil
  }

  static func cancel(_ id: UUID) {
    entries[id]?.editor.setPromotionResponderHold(false)
    if let entry = entries.removeValue(forKey: id) {
      entry.editor.alpha = entry.parkedAlpha ?? entry.editor.alpha
      entry.parkedAlpha = nil
      entry.isPortaled = false
      entry.editor.removeFromSuperview()
    }
    ports.removeValue(forKey: id)
  }

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
    editor.setPromotionResponderHold(true, releaseAfter: 1.0)
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
    owner.localEditor = nil
    entry.editor.setPromotionResponderHold(true)
    portal(entry, through: owner)
    if entry.parkedAlpha == nil {
      entry.parkedAlpha = entry.editor.alpha
    }
    entry.editor.alpha = 0.001
    return entry.editor.isFirstResponder
  }

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
