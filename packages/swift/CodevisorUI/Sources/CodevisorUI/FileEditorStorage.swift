import CodeHighlighter
import CodevisorTheming
import Foundation
import SwiftUI

/// Synchronizes one native editor with its session and shared document buffer.
@MainActor
final class FileEditorStorage: NSObject {
  private weak var session: FileEditorSession?
  let native = NativeFileEditor()
  private lazy var syntax = FileEditorHighlighting(textView: native.textView)
  private var highlightTheme: CodeHighlightTheme?
  private var foreground: FileColor = .fileEditorLabel
  private var appliedSelection = -1
  private var applying = false

  init(session: FileEditorSession) {
    self.session = session
    super.init()
    applying = true
    native.connect(self)
    native.text = session.document.text
    applying = false
  }

  func update(theme: Theme, highlight: CodeHighlightTheme?) {
    guard let session else { return }
    let document = session.document
    let changedTheme = highlight != highlightTheme || foreground != FileColor(theme.textPrimary)
    foreground = FileColor(theme.textPrimary)
    highlightTheme = highlight
    native.update(theme: theme, session: session)
    if native.text != document.text {
      applying = true
      native.text = document.text
      applying = false
      appliedSelection = -1
      scheduleHighlight(replaced: true)
    } else if changedTheme {
      scheduleHighlight()
    }
    if appliedSelection != session.selectionRequest {
      let length = (document.text as NSString).length
      let location = min(length, session.selection.location)
      native.revealSelection(
        NSRange(location: location, length: min(session.selection.length, length - location)))
      appliedSelection = session.selectionRequest
    }
    native.redrawGutter()
  }

  func undo() { native.textView.undoManager?.undo() }
  func redo() { native.textView.undoManager?.redo() }
  func replace(range: NSRange, with replacement: String) { native.replace(range: range, with: replacement) }
  func resignFocus() { native.resignFocus() }

  func changed() {
    guard !applying else { return }
    session?.document.edit(native.text)
    selectionChanged()
    scheduleHighlight()
    native.redrawGutter()
  }

  func selectionChanged() {
    guard !applying else { return }
    session?.selectionChanged(native.selection)
  }

  private func scheduleHighlight(replaced: Bool = false) {
    guard let document = session?.document else { return }
    syntax.configure(
      language: CodeHighlighter.language(forPath: document.name),
      theme: highlightTheme, foreground: foreground, replaced: replaced)
  }
}

struct FileSourceEditor: View {
  let session: FileEditorSession
  @Environment(\.theme) private var theme
  @Environment(\.codeHighlightTheme) private var highlight
  var body: some View {
    NativeFileSourceEditor(storage: session.storage, theme: theme, highlight: highlight)
      .onChange(of: session.document.snapshot?.version, initial: true) { _, _ in session.resolvePendingLine() }
      #if os(iOS)
        // UIKit keeps resting content clear of chrome; SwiftUI avoids the keyboard.
        .ignoresSafeArea(.container, edges: .vertical)
      #endif
  }
}
