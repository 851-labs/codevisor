import CTreeSitter
import Foundation

/// Borrows capture nodes synchronously; their document retains the C tree.
enum TreeSitterLocalReferences {
  static func resolve(
    _ matches: [TreeSitterQuery.Match], tree: OpaquePointer,
    name: (TreeSitterQuery.Capture) -> String
  ) -> Set<Int> {
    let root = ts_tree_root_node(tree)
    let rootKey = key(root)
    var scopes: [String: Bool] = [rootKey: true]
    var definitions: [TreeSitterQuery.Capture] = []
    var references: [TreeSitterQuery.Capture] = []
    collect(matches, scopes: &scopes, definitions: &definitions, references: &references)
    let namesByScope = definitionNames(definitions, scopes: scopes, rootKey: rootKey, name: name)
    var result = Set(definitions.map { $0.range.location * 2 })
    includeBoundReferences(references, scopes: scopes, namesByScope: namesByScope, name: name, result: &result)
    return result
  }

  private static func collect(
    _ matches: [TreeSitterQuery.Match], scopes: inout [String: Bool],
    definitions: inout [TreeSitterQuery.Capture], references: inout [TreeSitterQuery.Capture]
  ) {
    for match in matches {
      for capture in match.captures {
        switch capture.name {
        case "local.scope": scopes[key(capture.node)] = match.properties["local.scope-inherits"] != "false"
        case "local.definition": definitions.append(capture)
        case "local.reference": references.append(capture)
        default: break
        }
      }
    }
  }

  private static func definitionNames(
    _ definitions: [TreeSitterQuery.Capture], scopes: [String: Bool], rootKey: String,
    name: (TreeSitterQuery.Capture) -> String
  ) -> [String: Set<String>] {
    var namesByScope: [String: Set<String>] = [:]
    for definition in definitions {
      namesByScope[enclosingScopes(definition.node, scopes: scopes).first ?? rootKey, default: []].insert(
        name(definition))
    }
    return namesByScope
  }

  private static func includeBoundReferences(
    _ references: [TreeSitterQuery.Capture], scopes: [String: Bool], namesByScope: [String: Set<String>],
    name: (TreeSitterQuery.Capture) -> String, result: inout Set<Int>
  ) {
    for reference in references {
      let value = name(reference)
      if enclosingScopes(reference.node, scopes: scopes).contains(where: { namesByScope[$0]?.contains(value) == true })
      {
        result.insert(reference.range.location * 2)
      }
    }
  }

  private static func enclosingScopes(_ node: TSNode, scopes: [String: Bool]) -> [String] {
    var node = node
    var result: [String] = []
    while !ts_node_is_null(node) {
      let id = key(node)
      if let inherits = scopes[id] {
        result.append(id)
        if !inherits { break }
      }
      node = ts_node_parent(node)
    }
    return result
  }

  private static func key(_ node: TSNode) -> String {
    "\(ts_node_start_byte(node)):\(ts_node_end_byte(node)):\(String(cString: ts_node_type(node)))"
  }
}
