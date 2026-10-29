import CodevisorCore

struct McpSecretChanges {
  let entries: [McpSecretEntry]
  let savedNames: [String]

  var problem: String? {
    if names.contains(where: \.isEmpty) { return "Every entry needs a name." }
    if Set(names).count != names.count { return "Names must be unique." }
    if filled.contains(where: { $0.value.isEmpty && !isSaved($0) }) { return "Enter a value for each new entry." }
    return nil
  }

  var hasChanges: Bool { !changed.isEmpty || !removed.isEmpty }

  func body(isHTTP: Bool) -> UpdateMcpServerBody {
    if isHTTP {
      return UpdateMcpServerBody(
        headers: changed.isEmpty ? nil : changed, removeHeaders: removed.isEmpty ? nil : removed)
    }
    return UpdateMcpServerBody(env: changed.isEmpty ? nil : changed, removeEnv: removed.isEmpty ? nil : removed)
  }

  private var names: [String] { filled.map(trimmedName) }

  private var filled: [McpSecretEntry] {
    entries.filter { $0.existing || !trimmedName($0).isEmpty || !$0.value.isEmpty }
  }

  private func trimmedName(_ entry: McpSecretEntry) -> String {
    entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func isSaved(_ entry: McpSecretEntry) -> Bool {
    entry.existing && savedNames.contains(trimmedName(entry))
  }

  private var changed: [String: String] {
    Dictionary(
      filled.compactMap { entry -> (String, String)? in
        let name = trimmedName(entry)
        guard !name.isEmpty, !entry.value.isEmpty else { return nil }
        return (name, entry.value)
      },
      uniquingKeysWith: { _, last in last })
  }

  private var removed: [String] {
    let kept = Set(filled.filter { isSaved($0) || !$0.value.isEmpty }.map(trimmedName))
    return savedNames.filter { !kept.contains($0) }.sorted()
  }
}
