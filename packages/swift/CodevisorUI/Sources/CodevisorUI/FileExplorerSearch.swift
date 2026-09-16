import CodevisorCore
import Observation

@MainActor @Observable
final class FileExplorerSearch {
  private(set) var query = ""
  private(set) var result: ServerFileSearch?
  private(set) var isSearching = false
  private(set) var error: String?
  private var generation = 0

  var notice: String? {
    if result?.truncated == true {
      return "Search limit reached. Try a more specific filename or search inside a folder."
    }
    if (result?.skippedDirectories ?? 0) > 0 { return "Some folders couldn’t be searched." }
    return nil
  }

  func update(
    query: String,
    debounce: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) },
    search: (String) async throws -> ServerFileSearch
  ) async {
    generation += 1
    let request = generation
    self.query = query
    result = nil
    error = nil
    isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard isSearching else { return }
    defer { if generation == request { isSearching = false } }
    do {
      try await debounce()
      try Task.checkCancellation()
      let value = try await search(query)
      try Task.checkCancellation()
      guard generation == request else { return }
      result = value
    } catch {
      if generation == request, !isTaskCancellation(error) { self.error = serverErrorMessage(error) }
    }
  }
}
