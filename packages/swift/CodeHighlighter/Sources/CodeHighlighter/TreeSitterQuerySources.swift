import Foundation

/// The ordered bundled query sources used when a grammar is first loaded.
enum TreeSitterQuerySources {
  static func bases(for name: String) -> [String] {
    var bases = [name]
    if name == "cpp" { bases = ["c", "cpp"] }
    if ["javascript", "jsx", "typescript", "tsx"].contains(name) {
      bases = ["javascript"]
      if name == "typescript" || name == "tsx" { bases.append("typescript") }
    }
    return bases
  }

  static func source(_ kind: String, for name: String, bases: [String]) throws -> String {
    var fragments = try bases.compactMap { base -> String? in
      guard let url = Bundle.module.url(forResource: kind, withExtension: "scm", subdirectory: "Queries/\(base)")
      else { return nil }
      return try String(contentsOf: url, encoding: .utf8)
    }
    if kind == "highlights", ["javascript", "jsx", "tsx"].contains(name),
      let url = Bundle.module.url(
        forResource: "highlights-jsx", withExtension: "scm", subdirectory: "Queries/javascript")
    {
      fragments.append(try String(contentsOf: url, encoding: .utf8))
    }
    return fragments.joined(separator: "\n")
  }
}
