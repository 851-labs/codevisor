import CodeHighlighter
import CodevisorTheming
import SwiftUI

#if canImport(AppKit)
  import AppKit
  typealias FileTextEditActions = NSTextStorageEditActions
#else
  import UIKit
  typealias FileTextEditActions = NSTextStorage.EditActions
#endif

/// Captures actual text-storage edits, coalesces pending work, and applies only
/// current syntax patches. A skipped revision remains dirty in the parser session.
@MainActor
final class FileEditorHighlighting: NSObject, @preconcurrency NSTextStorageDelegate {
  private weak var textView: FileTextView?
  private var session: CodeHighlightDocument?
  private var language: String?
  private var theme: CodeHighlightTheme?
  #if canImport(AppKit)
    private var foreground: FileColor = .labelColor
  #else
    private var foreground: FileColor = .label
  #endif
  private var pending: [CodeHighlightDocument.Edit] = []
  private var revision = 0
  private var requested = false
  private var replaceSource = true
  private var task: Task<Void, Never>?

  init(textView: FileTextView) {
    self.textView = textView
    super.init()
    storage?.delegate = self
  }

  deinit { task?.cancel() }

  private var storage: NSTextStorage? {
    textView?.textStorage
  }

  func configure(language: String?, theme: CodeHighlightTheme?, foreground: FileColor, replaced: Bool) {
    if self.language != language {
      self.language = language
      session = language.map { CodeHighlightDocument(language: $0) }
      replaceSource = true
    }
    if self.theme != theme || self.foreground != foreground || replaced {
      revision += 1
      requested = true
    }
    self.theme = theme
    self.foreground = foreground
    if replaced { replaceSource = true; pending.removeAll() }
    request()
  }

  func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: FileTextEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    let oldLength = editedRange.length - delta
    guard oldLength >= 0, NSMaxRange(editedRange) <= textStorage.length else {
      replaceSource = true
      request()
      return
    }
    pending.append(
      .init(
        range: NSRange(location: editedRange.location, length: oldLength),
        text: (textStorage.string as NSString).substring(with: editedRange)))
    revision += 1
    requested = true
    request()
  }

  func request() {
    requested = true
    guard task == nil else { return }
    task = Task { [weak self] in
      // Returning to the executor lets TextKit finish its current edit before
      // reading text or modifying attributes. No timer is involved.
      while let self, self.requested, !Task.isCancelled {
        self.requested = false
        guard let storage = self.storage else { break }
        let version = self.revision
        let source = storage.string
        let fullHighlight = self.replaceSource
        let edits = self.replaceSource ? nil : self.pending
        self.pending.removeAll()
        self.replaceSource = false
        guard let session = self.session, let theme = self.theme else {
          self.applyPlainText(storage)
          continue
        }
        do {
          let update = try await session.update(
            source: source, edits: edits, themeJSON: theme.json, revision: version, forceFullHighlight: fullHighlight)
          guard !Task.isCancelled, self.revision == version, self.session === session,
            !self.hasMarkedText, let current = self.storage
          else { continue }
          self.apply(update, to: current)
          await session.acknowledge(revision: version)
        } catch {
          guard !Task.isCancelled else { break }
          // Retry from a complete snapshot on the next edit, preserving text.
          self.session = self.language.map { CodeHighlightDocument(language: $0) }
          self.replaceSource = true
          if self.revision == version { self.applyPlainText(storage) }
        }
      }
      self?.task = nil
    }
  }

  private var hasMarkedText: Bool {
    #if canImport(AppKit)
      textView?.hasMarkedText() ?? false
    #else
      textView?.markedTextRange != nil
    #endif
  }

  private func applyPlainText(_ storage: NSTextStorage) {
    guard !hasMarkedText else { return }
    storage.beginEditing()
    storage.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: 0, length: storage.length))
    storage.endEditing()
  }

  private func apply(_ update: CodeHighlightDocument.Update, to storage: NSTextStorage) {
    let range = update.invalidatedRange
    guard NSMaxRange(range) <= storage.length else { return }
    storage.beginEditing()
    storage.addAttribute(.foregroundColor, value: foreground, range: range)
    #if canImport(AppKit)
      let base = NSFont.monospacedSystemFont(ofSize: textView?.font?.pointSize ?? 13, weight: .regular)
    #else
      let base = UIFont.monospacedSystemFont(ofSize: textView?.font?.pointSize ?? 13, weight: .regular)
    #endif
    storage.addAttribute(.font, value: base, range: range)
    for span in update.spans {
      if let color = span.style.foreground, let rgba = RGBA(css: color) {
        storage.addAttribute(.foregroundColor, value: FileColor(Color(rgba: rgba)), range: span.range)
      }
      if span.style.bold || span.style.italic {
        #if canImport(AppKit)
          var traits: NSFontTraitMask = []
          if span.style.bold { traits.insert(.boldFontMask) }
          if span.style.italic { traits.insert(.italicFontMask) }
          let font = NSFontManager.shared.convert(base, toHaveTrait: traits)
        #else
          var traits: UIFontDescriptor.SymbolicTraits = []
          if span.style.bold { traits.insert(.traitBold) }
          if span.style.italic { traits.insert(.traitItalic) }
          let font =
            base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: base.pointSize) } ?? base
        #endif
        storage.addAttribute(.font, value: font, range: span.range)
      }
    }
    storage.endEditing()
    textView?.typingAttributes[.foregroundColor] = foreground
    textView?.typingAttributes[.font] = base
  }
}
