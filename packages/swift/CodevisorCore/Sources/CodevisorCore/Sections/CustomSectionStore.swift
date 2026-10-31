import ACPKit
import Foundation
import Observation

@MainActor
@Observable
public final class CustomSectionStore {
  public static let botNamespace = "bot-sections"
  public static let workspaceNamespace = "workspace-sections"

  private static let sectionPrefix = "section:"
  private static let memberPrefix = "member:"

  public let namespace: String
  @ObservationIgnored private let configSync: ConfigSync

  public init(configSync: ConfigSync, namespace: String) {
    self.configSync = configSync
    self.namespace = namespace
  }

  public var sections: [CustomSection] {
    liveEntries.compactMap(Self.section(from:)).sorted(by: CustomSection.precedes)
  }

  public var membership: [UUID: UUID] {
    let known = Set(sections.map(\.id))
    var membership: [UUID: UUID] = [:]
    for entry in liveEntries {
      guard let (memberID, sectionID) = Self.member(from: entry), known.contains(sectionID) else { continue }
      membership[memberID] = sectionID
    }
    return membership
  }

  @discardableResult
  public func create(name: String) -> CustomSection {
    let id = UUID()
    let position = WorkspacePosition.between(sections.last?.position, nil, id: id)!
    let section = CustomSection(id: id, name: name, position: position)
    write(section)
    return section
  }

  public func rename(_ sectionID: UUID, to name: String) {
    guard var section = sections.first(where: { $0.id == sectionID }) else { return }

    section.name = name
    write(section)
  }

  public func delete(_ sectionID: UUID) {
    for (memberID, member) in membership where member == sectionID {
      configSync.remove(namespace: namespace, key: Self.memberPrefix + Self.key(memberID))
    }
    configSync.remove(namespace: namespace, key: Self.sectionPrefix + Self.key(sectionID))
  }

  public func move(_ memberID: UUID, to sectionID: UUID?) {
    guard membership[memberID] != sectionID else { return }

    let key = Self.memberPrefix + Self.key(memberID)
    if let sectionID {
      configSync.set(namespace: namespace, key: key, value: .object(["section": .string(Self.key(sectionID))]))
    } else {
      configSync.remove(namespace: namespace, key: key)
    }
  }

  public func forget(_ memberID: UUID) {
    guard membership[memberID] != nil else { return }

    configSync.remove(namespace: namespace, key: Self.memberPrefix + Self.key(memberID))
  }

  public func moveSection(_ sectionID: UUID, toIndex index: Int) {
    var others = sections
    guard let from = others.firstIndex(where: { $0.id == sectionID }) else { return }

    let moving = others.remove(at: from)
    let index = min(max(0, index), others.count)
    let lower = index > 0 ? others[index - 1].position : nil
    let upper = index < others.count ? others[index].position : nil
    guard let position = WorkspacePosition.between(lower, upper, id: sectionID), position != moving.position else {
      return
    }
    write(CustomSection(id: moving.id, name: moving.name, position: position))
  }

  private var liveEntries: [ServerSyncEntry] {
    _ = configSync.revisionsByNamespace[namespace]
    return configSync.entries(namespace: namespace).filter { $0.deleted != true }
  }

  private func write(_ section: CustomSection) {
    let value: JSONValue = .object(["name": .string(section.name), "position": .string(section.position)])
    configSync.set(namespace: namespace, key: Self.sectionPrefix + Self.key(section.id), value: value)
  }

  private static func key(_ id: UUID) -> String {
    id.uuidString.lowercased()
  }

  private static func section(from entry: ServerSyncEntry) -> CustomSection? {
    guard entry.key.hasPrefix(sectionPrefix),
      let id = UUID(uuidString: String(entry.key.dropFirst(sectionPrefix.count))),
      case let .object(fields) = entry.value,
      case let .string(name)? = fields["name"],
      case let .string(position)? = fields["position"], WorkspacePosition.isValid(position)
    else { return nil }
    return CustomSection(id: id, name: name, position: position)
  }

  private static func member(from entry: ServerSyncEntry) -> (UUID, UUID)? {
    guard entry.key.hasPrefix(memberPrefix),
      let memberID = UUID(uuidString: String(entry.key.dropFirst(memberPrefix.count))),
      case let .object(fields) = entry.value,
      case let .string(section)? = fields["section"], let sectionID = UUID(uuidString: section)
    else { return nil }
    return (memberID, sectionID)
  }
}
