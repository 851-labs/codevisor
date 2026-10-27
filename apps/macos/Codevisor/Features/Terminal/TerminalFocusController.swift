import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI
import GhosttyKit

struct HostWindowCapture: NSViewRepresentable {
  var onWindow: (NSWindow?) -> Void

  final class CaptureView: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindow?(window)
    }
  }

  func makeNSView(context: Context) -> CaptureView {
    let view = CaptureView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ nsView: CaptureView, context: Context) {
    nsView.onWindow = onWindow
  }
}

@MainActor
final class TerminalFocusController {

  weak var composerTextView: SubmittingTextView?
  weak var hostWindow: NSWindow? {
    didSet { observeFirstResponder() }
  }

  var onChatComposerFocused: ((UUID) -> Void)?
  var workspaceCommandHandler: ((PaneGroupCommand) -> Bool)?
  var canFocusChat: ((UUID) -> Bool)?
  var navigationRevision: (() -> Int)?
  private let deferredComposerFocus = DeferredPaneFocus()

  private var responderObservation: NSKeyValueObservation?

  private func observeFirstResponder() {
    responderObservation = hostWindow?.observe(
      \.firstResponder, options: [.new]
    ) { [weak self] window, _ in
      MainActor.assumeIsolated {
        let responder = window.firstResponder
        let revision = self?.navigationRevision?()
        Task { @MainActor [weak self] in
          guard let self, self.navigationRevision?() == revision,
            self.hostWindow === window, window.firstResponder === responder
          else { return }
          self.firstResponderChanged(responder)
        }
      }
    }
  }

  private func firstResponderChanged(_ responder: NSResponder?) {
    guard let view = responder as? NSView, view.window === hostWindow,
      hostWindow?.isKeyWindow == true
    else { return }
    for (chatId, box) in chatComposers {
      if let composer = box.view, view === composer || view.isDescendant(of: composer) {
        onChatComposerFocused?(chatId)
        return
      }
    }
    for (chatId, box) in chatQuestionPickers {
      if let picker = box.view, view === picker {
        onChatComposerFocused?(chatId)
        return
      }
    }
    for (chatId, box) in chatTranscripts {
      if let transcript = box.view, view === transcript || view.isDescendant(of: transcript) {
        onChatComposerFocused?(chatId)
        return
      }
    }
  }
  weak var transcriptView: NSView?
  weak var centerGroup: PaneGroupModel?
  private var typeToFocusMonitor: Any?

  private final class WeakTextView {
    weak var view: SubmittingTextView?
    init(_ view: SubmittingTextView) { self.view = view }
  }

  private var chatComposers: [UUID: WeakTextView] = [:]
  private final class WeakNSView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
  }

  private var chatTranscripts: [UUID: WeakNSView] = [:]
  private var chatQuestionPickers: [UUID: WeakNSView] = [:]
  private var pendingComposerFocus: UUID?

  func registerComposer(_ view: SubmittingTextView, forChat sessionId: UUID) {
    chatComposers[sessionId] = WeakTextView(view)
    view.onWindowChanged = { [weak self] in self?.deferredComposerFocus.retry() }
    if pendingComposerFocus == sessionId {
      pendingComposerFocus = nil
      focusWhenWindowed(view, forChat: sessionId)
    }
  }

  func registerTranscript(_ view: NSView, forChat sessionId: UUID) {
    chatTranscripts[sessionId] = WeakNSView(view)
  }

  func registerQuestionPicker(_ view: NSView, forChat sessionId: UUID) {
    chatQuestionPickers[sessionId] = WeakNSView(view)
    if let pending = pendingComposerFocus, canFocusChat?(pending) == false {
      pendingComposerFocus = nil
    }
    if pendingComposerFocus == sessionId {
      pendingComposerFocus = nil
      focusWhenWindowed(view, forChat: sessionId)
      return
    }
    guard pendingComposerFocus == nil else { return }
    guard canFocusChat?(sessionId) != false else { return }
    focusWhenWindowed(view, forChat: sessionId) { [weak self] window in
      self?.questionPickerMayTakeFocus(in: window, forChat: sessionId) ?? false
    }
  }

  func unregisterQuestionPicker(_ view: NSView, forChat sessionId: UUID) {
    guard chatQuestionPickers[sessionId]?.view === view else { return }
    chatQuestionPickers[sessionId] = nil
    guard let window = view.window else { return }
    let responder = window.firstResponder
    let pickerHeldFocus =
      responder === view
      || responder === window
      || isQuestionPickerNotesEditor(responder)
    if pickerHeldFocus {
      requestComposerFocus(forChat: sessionId)
    }
  }

  @discardableResult
  func focusComposerText(forChat sessionId: UUID) -> SubmittingTextView? {
    guard let composer = chatComposers[sessionId]?.view, composer.isEditable,
      let window = composer.window, window.makeFirstResponder(composer)
    else { return nil }
    return composer
  }

  func typeIntoComposer(_ event: NSEvent, forChat sessionId: UUID) {
    focusComposerText(forChat: sessionId)?.keyDown(with: event)
  }

  private func isQuestionPickerNotesEditor(_ responder: NSResponder?) -> Bool {
    guard let textView = responder as? SubmittingTextView else { return false }
    if textView === composerTextView { return false }
    return !chatComposers.values.contains { $0.view === textView }
  }

  private func questionPickerMayTakeFocus(in window: NSWindow, forChat sessionId: UUID) -> Bool {
    guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
    guard let responder = window.firstResponder, responder !== window else { return true }
    if responder is Ghostty.SurfaceView { return false }
    if let anchor = responder as? NSView,
      chatQuestionPickers.contains(where: { $0.key != sessionId && $0.value.view === anchor })
    {
      return false
    }
    if let textView = responder as? NSTextView, textView.isEditable {
      return textView === chatComposers[sessionId]?.view
    }
    if let field = responder as? NSTextField, field.isEditable { return false }
    return true
  }

  private func composerAreaView(forChat sessionId: UUID) -> NSView? {
    if let picker = chatQuestionPickers[sessionId]?.view { return picker }
    return chatComposers[sessionId]?.view
  }

  private var fallbackQuestionPicker: NSView? {
    let live = chatQuestionPickers.values.compactMap(\.view)
    return live.count == 1 ? live[0] : nil
  }

  func requestComposerFocus(forChat sessionId: UUID) {
    guard canFocusChat?(sessionId) != false else { return }
    deferredComposerFocus.cancel()
    pendingComposerFocus = nil
    if let view = composerAreaView(forChat: sessionId) {
      focusWhenWindowed(view, forChat: sessionId) { [weak self] window in
        guard let transcript = self?.chatTranscripts[sessionId]?.view,
          let responder = window.firstResponder as? NSView
        else { return true }
        return !responder.isDescendant(of: transcript)
      }
    } else {
      pendingComposerFocus = sessionId
    }
  }

  private func focusWhenWindowed(
    _ view: NSView,
    forChat sessionId: UUID,
    given shouldFocus: ((NSWindow) -> Bool)? = nil
  ) {
    let revision = navigationRevision?()
    deferredComposerFocus.request(
      isCurrent: { [weak self, weak view] in
        guard let self, view != nil else { return false }
        return self.navigationRevision?() == revision && self.canFocusChat?(sessionId) != false
      },
      focus: { [weak view] in
        guard let view, let window = view.window else { return false }
        guard window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
          shouldFocus?(window) ?? true
        else { return true }
        return window.makeFirstResponder(view)
      }
    )
  }

  func focusComposer() {
    if let chatId = centerGroup?.state.selectedPane?.chatSessionId,
      let view = composerAreaView(forChat: chatId)
    {
      if canFocusChat?(chatId) != false { view.window?.makeFirstResponder(view) }
      return
    }
    guard let view = (composerTextView as NSView?) ?? fallbackQuestionPicker else { return }
    view.window?.makeFirstResponder(view)
  }

  func focusPaneBackground() {
    guard let window = hostWindow,
      window.isKeyWindow,
      window.attachedSheet == nil,
      NSApp.modalWindow == nil
    else { return }
    window.makeFirstResponder(nil)
  }

  func startTypeToFocus() {
    guard typeToFocusMonitor == nil else { return }
    typeToFocusMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .leftMouseDown]
    ) { [weak self] event in
      guard let self else { return event }
      switch event.type {
      case .keyDown:
        if self.handleTabCommand(event) { return nil }
        return self.handleTypeToFocus(event)
      case .leftMouseDown: return self.handleTranscriptClick(event)
      default: return event
      }
    }
  }

  private func handleTabCommand(_ event: NSEvent) -> Bool {
    guard let window = hostWindow ?? composerTextView?.window,
      event.window === window,
      window.isKeyWindow,
      window.attachedSheet == nil,
      NSApp.modalWindow == nil,
      !(window.firstResponder is Ghostty.SurfaceView)
    else { return false }
    guard let command = ShortcutCatalog.paneCommand(for: event) else { return false }
    if workspaceCommandHandler?(command) == true { return true }
    guard let centerGroup else { return false }
    centerGroup.handleCommand(command)
    return true
  }

  func stopTypeToFocus() {
    deferredComposerFocus.cancel()
    pendingComposerFocus = nil
    workspaceCommandHandler = nil
    guard let typeToFocusMonitor else { return }
    NSEvent.removeMonitor(typeToFocusMonitor)
    self.typeToFocusMonitor = nil
  }

  private func handleTypeToFocus(_ event: NSEvent) -> NSEvent? {
    guard let target = typeToFocusTarget(),
      let window = target.window,
      event.window === window,
      window.isKeyWindow,
      window.attachedSheet == nil,
      NSApp.modalWindow == nil,
      window.firstResponder !== target,
      Self.isTypeToFocusEvent(
        event,
        includesQuestionPickerCommands: target is QuestionPickerKeyView
      )
    else {
      return event
    }

    if let currentTextView = window.firstResponder as? NSTextView,
      currentTextView.isEditable
    {
      return event
    }
    if let currentTextField = window.firstResponder as? NSTextField,
      currentTextField.isEditable
    {
      return event
    }
    if window.firstResponder is Ghostty.SurfaceView {
      return event
    }
    if let responder = window.firstResponder as? NSView,
      chatQuestionPickers.values.contains(where: { $0.view === responder })
    {
      return event
    }

    guard window.makeFirstResponder(target) else { return event }

    return event
  }

  private func typeToFocusTarget() -> NSView? {
    if let selectedPane = centerGroup?.state.selectedPane {
      guard selectedPane.kind == .chat else { return nil }
      if let chatId = selectedPane.chatSessionId {
        if let picker = chatQuestionPickers[chatId]?.view {
          return picker
        }
        if let textView = chatComposers[chatId]?.view, textView.isEditable {
          return textView
        }
        return nil
      }
    }
    if let textView = composerTextView, textView.isEditable {
      return textView
    }
    return fallbackQuestionPicker
  }

  private func handleTranscriptClick(_ event: NSEvent) -> NSEvent? {
    var zones: [(chatId: UUID?, view: NSView)] = chatTranscripts.compactMap { id, box in
      box.view.map { (id, $0) }
    }
    if let transcriptView, !zones.contains(where: { $0.view === transcriptView }) {
      zones.append((nil, transcriptView))
    }
    for zone in zones {
      guard let window = zone.view.window,
        event.window === window,
        window.attachedSheet == nil,
        NSApp.modalWindow == nil,
        let zoneSuperview = zone.view.superview
      else { continue }
      let point = zoneSuperview.convert(event.locationInWindow, from: nil)
      guard let hitView = zone.view.hitTest(point) else { continue }

      let responderBeforeClick = window.firstResponder
      if let composer = zone.chatId.flatMap({ chatComposers[$0]?.view }),
        responderBeforeClick === composer
      {
        return event
      }

      let revision = navigationRevision?()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.navigationRevision?() == revision,
          zone.view.window === window, window.firstResponder === responderBeforeClick
        else { return }

        if let responderView = responderBeforeClick as? NSView,
          hitView === responderView || hitView.isDescendant(of: responderView)
        {
          return
        }

        window.makeFirstResponder(zone.view)
      }
      return event
    }
    return event
  }

  private static func isTypeToFocusEvent(
    _ event: NSEvent,
    includesQuestionPickerCommands: Bool = false
  ) -> Bool {
    let modifiers = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)

    if includesQuestionPickerCommands {
      let pickerModifiers = modifiers.subtracting([.function, .numericPad])
      if pickerModifiers.isEmpty {
        switch event.specialKey {
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
          return true
        default:
          break
        }
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53
          || event.charactersIgnoringModifiers == " "
        {
          return true
        }
      }
    }

    guard modifiers.intersection([.command, .control, .function]).isEmpty,
      event.specialKey == nil
    else { return false }

    return event.characters != " " && event.characters != "\u{00A0}"
  }
}
