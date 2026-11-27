struct NavigationRecordChanges<Record: Equatable> {
  let upserts: [Record]
  let removedIds: [String]

  init(new: [Record], old: [Record], id: (Record) -> String) {
    let previous = Self.byKey(old, id: id)
    let current = Self.byKey(new, id: id)
    upserts = current.filter { previous[$0.key] != $0.value }.map(\.value)
    removedIds = previous.filter { current[$0.key] == nil }.map { id($0.value) }
  }

  static func ordered(_ records: [Record], id: (Record) -> String) -> [Record] {
    byKey(records, id: id).sorted { $0.key < $1.key }.map(\.value)
  }

  private static func byKey(_ records: [Record], id: (Record) -> String) -> [String: Record] {
    Dictionary(records.map { (id($0).lowercased(), $0) }, uniquingKeysWith: { _, latest in latest })
  }
}
