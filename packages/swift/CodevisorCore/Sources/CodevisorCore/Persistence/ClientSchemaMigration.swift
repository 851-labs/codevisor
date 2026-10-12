import CryptoKit
import Foundation

public struct ClientSchemaMigration: Sendable {
  public let id: Int
  public let name: String
  public let sql: String

  public init(id: Int, name: String, sql: String) {
    self.id = id
    self.name = name
    self.sql = sql
  }

  var checksum: String {
    let digest = SHA256.hash(data: Data("\(id)\n\(name)\n\(sql)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func validateDeclarationOrder(
    migrations: [ClientSchemaMigration],
    ordered: [ClientSchemaMigration]
  ) throws {
    guard ordered.map(\.id) == migrations.map(\.id),
      Set(ordered.map(\.id)).count == ordered.count
    else {
      throw ClientDatabaseError(
        operation: "migration validation",
        detail: "Migration ids must be unique and declared in ascending order"
      )
    }
  }

  static func validateAppliedPrefix(
    ordered: [ClientSchemaMigration],
    applied: [Int: (name: String, checksum: String)]
  ) throws {
    let declaredIDs = ordered.map(\.id)
    let appliedIDs = applied.keys.sorted()
    guard Array(declaredIDs.prefix(appliedIDs.count)) == appliedIDs else {
      throw ClientDatabaseError(
        operation: "migration validation",
        detail: "Database schema is newer than this client or has a migration gap"
      )
    }
  }

  static func validateAppliedMetadata(
    ordered: [ClientSchemaMigration],
    applied: [Int: (name: String, checksum: String)]
  ) throws {
    for migration in ordered {
      if let existing = applied[migration.id] {
        guard existing.name == migration.name,
          existing.checksum == migration.checksum
        else {
          throw ClientDatabaseError(
            operation: "migration validation",
            detail: "Applied migration \(migration.id) was edited"
          )
        }
      }
    }
  }
}
