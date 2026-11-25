@MainActor
public struct FileEditModeToggle {
  private let page: FilePaneModel

  public init?(page: FilePaneModel) {
    guard page.canEdit || page.access == .editing else { return nil }

    self.page = page
  }

  public var isEditing: Bool { page.access == .editing }

  public var title: String {
    if !isEditing { return "Edit" }
    return page.document.hasPreview ? "Show Preview" : "Stop Editing"
  }

  public var systemImage: String { isEditing ? "eye" : "pencil" }

  public func toggle() {
    if isEditing { page.stopEditing() } else { page.startEditing() }
  }
}
