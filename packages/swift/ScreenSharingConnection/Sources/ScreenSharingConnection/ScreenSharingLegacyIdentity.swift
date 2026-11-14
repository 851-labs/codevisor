import Foundation

public struct ScreenSharingLegacyIdentity: Equatable, Sendable {
  public static let paneType = "machine-desktop"

  public let workspaceId: UUID
  public let paneId: UUID

  public init(workspaceId: UUID, installId: UUID) {
    self.workspaceId = workspaceId
    paneId = Self.mix(workspaceId, installId)
  }

  private static func mix(_ first: UUID, _ second: UUID) -> UUID {
    let mixed = zip(Self.bytes(of: first), Self.bytes(of: second)).map { $0 ^ $1 }
    return mixed.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
  }

  private static func bytes(of id: UUID) -> [UInt8] {
    withUnsafeBytes(of: id.uuid) { Array($0) }
  }
}
