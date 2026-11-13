import Foundation

nonisolated enum FolderAccessProjectList {
  static let named = 2

  static func question(projects: [String], folderPath: String) -> String {
    let place = (folderPath as NSString).abbreviatingWithTildeInPath
    return "\(subject(projects)) located in \(place). \(request(for: projects.count))"
  }

  private static func subject(_ projects: [String]) -> String {
    let shown = projects.prefix(named).map { "“\($0)”" }
    let hidden = projects.count - shown.count
    if hidden > 0 { return "\(shown.joined(separator: ", ")), and \(more(hidden)) are" }
    if shown.count == 2 { return "\(shown.joined(separator: " and ")) are" }
    return "\(shown.first ?? "A project") is"
  }

  private static func more(_ hidden: Int) -> String {
    hidden == 1 ? "1 more project" : "\(hidden) more projects"
  }

  private static func request(for count: Int) -> String {
    count == 1
      ? "Would you like to give Codevisor access to this project?"
      : "Would you like to give Codevisor access to these projects?"
  }
}
