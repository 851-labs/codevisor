import Foundation

extension PaneDescriptorState {
  /// The pane's own title: a terminal shows what is running in it, and plain
  /// "Terminal" otherwise (older panes were numbered "Terminal N"; the number
  /// told nothing apart). A name someone chose (a rename, an agent task's
  /// description) is deliberate, so the program's title never replaces it.
  /// Tab-level renames (`WorkspaceTab.customTitle`) take precedence over this.
  public var displayName: String {
    guard kind == .terminal, Self.isDefaultTerminalName(name) else { return name }
    return liveTitle ?? Self.defaultTerminalName
  }

  /// What a new terminal pane is called until something runs in it.
  public static let defaultTerminalName = "Terminal"

  /// Programs may set any string, including blank or multi-line titles; a
  /// tab label needs one trimmed line, and a blank title means "no title".
  static func normalizedLiveTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let line = title.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return line.isEmpty ? nil : line
  }

  private static func isDefaultTerminalName(_ name: String) -> Bool {
    guard name.hasPrefix("Terminal") else { return false }
    let suffix = name.dropFirst("Terminal".count)
    return suffix.isEmpty || (suffix.hasPrefix(" ") && Int(suffix.dropFirst()) != nil)
  }
}
