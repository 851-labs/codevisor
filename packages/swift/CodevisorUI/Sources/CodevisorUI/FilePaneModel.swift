import CodevisorCore
import Foundation
import Observation

/// Pane presentation shared by the native window toolbar and the document.
/// The document store separately owns file contents and recoverable drafts.
@MainActor @Observable
public final class FilePaneModel {
  public let id: UUID
  public private(set) var path: String
  public let rootPath: String
  public let machineId: String
  public let client: any CodevisorServerClienting
  public var showsExplorer = false
  public var showsFind = false
  public var showsReplacement = false
  public var showsGoToLine = false
  public var showsConflict = false
  public var showsDetails = false
  public var findText = ""
  public var replacement = ""
  public var lineText = ""
  @ObservationIgnored public var onNavigate: ((String) -> Void)?
  @ObservationIgnored private let sessions: FileEditorSessions
  let explorer: FileExplorerModel

  public init(id: UUID, path: String, rootPath: String, machineId: String, client: any CodevisorServerClienting) {
    self.id = id
    self.path = path
    self.rootPath = rootPath
    self.machineId = machineId
    self.client = client
    sessions = FileEditorSessions { path in
      FileDocumentStore.shared.document(machineId: machineId, path: path, client: client)
    }
    explorer = FileExplorerModel(root: rootPath, machineId: machineId, client: client)
  }

  public var document: FileDocumentModel { editor.document }

  public var editor: FileEditorSession { sessions.editor(for: path) }

  public func close() { sessions.close() }

  public var isBrowsing: Bool { path.hasSuffix("/") }
  public var title: String { isBrowsing ? "Open File" : document.name }
  public var canSave: Bool {
    document.isDirty && document.isEditable && !document.isSaving && document.conflict == nil
  }

  public func navigate(to target: String, notify: Bool = true) {
    if path != target {
      document.flushAutosave()
      path = target
      if notify { onNavigate?(target) }
    }
    showsExplorer = false
  }

  func findNext() {
    guard !findText.isEmpty else { return }
    let source = document.text as NSString
    let start = min(source.length, NSMaxRange(editor.selection))
    var range = source.range(
      of: findText, options: .caseInsensitive, range: NSRange(location: start, length: source.length - start))
    if range.location == NSNotFound { range = source.range(of: findText, options: .caseInsensitive) }
    if range.location != NSNotFound {
      editor.select(range)
    }
  }

  func replaceSelection() {
    let source = document.text as NSString
    let selected = editor.selection
    if selected.length > 0, NSMaxRange(selected) <= source.length,
      source.substring(with: selected).localizedCaseInsensitiveCompare(findText) == .orderedSame
    {
      editor.replaceSelection(with: replacement)
    }
    findNext()
  }
}
