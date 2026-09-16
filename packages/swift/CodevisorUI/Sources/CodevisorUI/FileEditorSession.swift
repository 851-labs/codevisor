import Foundation
import Observation

/// One pane's presentation, selection, and undo history for a shared document.
@MainActor @Observable
public final class FileEditorSession {
  public let document: FileDocumentModel
  public var preview = false
  public var wrapsLines = false
  public var showsLineNumbers = true
  public private(set) var selection = NSRange(location: 0, length: 0)
  public private(set) var cursorLine = 1
  public private(set) var cursorColumn = 1
  private(set) var selectionRequest = 0
  @ObservationIgnored private var pendingLine: Int?
  @ObservationIgnored private var nativeStorage: FileEditorStorage?

  init(document: FileDocumentModel) { self.document = document }

  var storage: FileEditorStorage {
    if let nativeStorage { return nativeStorage }
    let storage = FileEditorStorage(session: self)
    nativeStorage = storage
    return storage
  }

  public func undo() { nativeStorage?.undo() }
  public func redo() { nativeStorage?.redo() }
  func resignFocus() { nativeStorage?.resignFocus() }
  func replaceSelection(with replacement: String) {
    nativeStorage?.replace(range: selection, with: replacement)
  }

  func close() {
    resignFocus()
    nativeStorage = nil
    document.flushAutosave()
  }

  func select(_ range: NSRange) {
    selectionChanged(range)
    selectionRequest &+= 1
    preview = false
  }

  func selectionChanged(_ range: NSRange) {
    let source = document.text as NSString
    let location = min(source.length, range.location)
    selection = NSRange(location: location, length: min(range.length, source.length - location))
    let prefix = source.substring(to: location)
    cursorLine = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    cursorColumn = (prefix.components(separatedBy: "\n").last?.count ?? 0) + 1
  }

  public func goToLine(_ line: Int) {
    preview = false
    guard document.snapshot != nil else { pendingLine = line; return }
    let source = document.text as NSString
    var location = 0
    for _ in 1..<max(1, line) {
      let range = source.range(of: "\n", range: NSRange(location: location, length: source.length - location))
      if range.location == NSNotFound { break }
      location = range.location + 1
    }
    select(NSRange(location: location, length: 0))
  }

  func resolvePendingLine() {
    guard document.snapshot != nil, let line = pendingLine else { return }
    pendingLine = nil
    goToLine(line)
  }
}
