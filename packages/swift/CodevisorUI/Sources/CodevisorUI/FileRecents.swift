import Foundation
import Observation

/// Recently viewed workspace files, bounded and isolated by machine and
/// workspace root so every file pane on the same workspace shares one list.
@MainActor @Observable
public final class FileRecents {
  public static let shared = FileRecents()
  public static let limit = 20
  @ObservationIgnored private let defaults: UserDefaults?
  private var scopes: [String: [String]] = [:]

  public init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

  public func paths(machineId: String, root: String) -> [String] {
    let scope = Self.scope(machineId: machineId, root: root)
    if let cached = scopes[scope] { return cached }
    let saved = defaults?.stringArray(forKey: scope) ?? []
    scopes[scope] = saved
    return saved
  }

  /// Moves `path` to the front. Only files inside `root` are remembered;
  /// attachments and files elsewhere never appear in a workspace's list.
  public func record(_ path: String, machineId: String, root: String) {
    guard path.hasPrefix(Self.directoryPrefix(root)), !path.hasSuffix("/") else { return }
    var recent = paths(machineId: machineId, root: root)
    if recent.first == path { return }
    recent.removeAll { $0 == path }
    recent.insert(path, at: 0)
    recent = Array(recent.prefix(Self.limit))
    save(recent, machineId: machineId, root: root)
  }

  /// Forgets a path that no longer opens (deleted or moved on the machine).
  public func remove(_ path: String, machineId: String, root: String) {
    var recent = paths(machineId: machineId, root: root)
    guard recent.contains(path) else { return }
    recent.removeAll { $0 == path }
    save(recent, machineId: machineId, root: root)
  }

  private func save(_ recent: [String], machineId: String, root: String) {
    let scope = Self.scope(machineId: machineId, root: root)
    scopes[scope] = recent
    defaults?.set(recent, forKey: scope)
  }

  private static func scope(machineId: String, root: String) -> String {
    "fileRecents.\(machineId).\(directoryPrefix(root))"
  }

  private static func directoryPrefix(_ root: String) -> String {
    root.hasSuffix("/") ? root : root + "/"
  }
}
