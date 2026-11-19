import Foundation

struct ReopenRecord {
  let path: String

  func add(_ apps: [String]) throws {
    let merged = Self.merging(apps, into: try? String(contentsOfFile: path, encoding: .utf8))
    guard !merged.isEmpty else { return }

    try merged.write(toFile: path, atomically: true, encoding: .utf8)
  }

  static func merging(_ apps: [String], into existing: String?) -> String {
    var paths = existing?.split(separator: "\n").map(String.init) ?? []
    for app in apps where !paths.contains(app) { paths.append(app) }
    return paths.map { $0 + "\n" }.joined()
  }
}
