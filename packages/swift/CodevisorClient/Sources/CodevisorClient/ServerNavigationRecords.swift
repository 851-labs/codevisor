import Foundation

/// A sidebar folder, replicated to every machine of the account. A deleted
/// folder stays as a tombstone so an older copy can never bring it back.
public struct ServerNavigationFolder: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  /// Its place among top-level sidebar items, in the workspaces'
  /// `sidebarPosition` key space.
  public var position: String
  public var collapsed: Bool
  public var deleted: Bool
  /// The writer's clock stamp; the newest revision wins everywhere.
  public var revision: String

  public init(
    id: String, name: String, position: String, collapsed: Bool = false, deleted: Bool = false,
    revision: String
  ) {
    self.id = id
    self.name = name
    self.position = position
    self.collapsed = collapsed
    self.deleted = deleted
    self.revision = revision
  }
}

/// An account-wide navigation setting replicated to every machine, such as
/// `sidebar.grouping` or `project.order.<projectId>`.
public struct ServerNavigationSetting: Codable, Equatable, Sendable {
  public var key: String
  public var value: String
  public var revision: String

  public init(key: String, value: String, revision: String) {
    self.key = key
    self.value = value
    self.revision = revision
  }
}

/// Replicated navigation records: what a machine holds, or a write to it.
public struct ServerNavigationRecords: Codable, Equatable, Sendable {
  public var folders: [ServerNavigationFolder]
  public var settings: [ServerNavigationSetting]

  public init(folders: [ServerNavigationFolder] = [], settings: [ServerNavigationSetting] = []) {
    self.folders = folders
    self.settings = settings
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    folders = try container.decodeIfPresent([ServerNavigationFolder].self, forKey: .folders) ?? []
    settings = try container.decodeIfPresent([ServerNavigationSetting].self, forKey: .settings) ?? []
  }

  public var isEmpty: Bool { folders.isEmpty && settings.isEmpty }

  /// These records with `newer` laid over them, keeping the newest revision
  /// of each folder and setting -- the same rule every machine applies.
  public func merging(_ newer: ServerNavigationRecords) -> ServerNavigationRecords {
    func merge<T>(_ current: [T], _ changes: [T], id: (T) -> String, revision: (T) -> String) -> [T] {
      var records = Dictionary(
        current.map { (id($0).lowercased(), $0) },
        uniquingKeysWith: { a, b in
          revision(a) >= revision(b) ? a : b
        })
      for record in changes {
        let key = id(record).lowercased()
        if let existing = records[key], revision(existing) >= revision(record) { continue }
        records[key] = record
      }
      return records.sorted { $0.key < $1.key }.map(\.value)
    }
    return ServerNavigationRecords(
      folders: merge(folders, newer.folders, id: \.id, revision: \.revision),
      settings: merge(settings, newer.settings, id: \.key, revision: \.revision))
  }
}

extension CodevisorServerClient {
  /// Writes records to this machine; it keeps each one only when its
  /// revision is newer, and answers with what it now holds for them.
  public func putNavigationRecords(_ records: ServerNavigationRecords) async throws -> ServerNavigationRecords {
    try await send("/v1/navigation/records", method: "PUT", body: records)
  }
}
