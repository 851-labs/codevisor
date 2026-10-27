import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class PluginCatalogModel {
  public typealias Sleep = @Sendable (Duration) async throws -> Void

  public private(set) var entries: [ServerPluginCatalogEntry] = []
  public private(set) var query = ""
  public private(set) var isLoading = true
  public private(set) var installing: Set<String> = []
  public var errorMessage: String?

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private let sleep: Sleep
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  public init(
    client: any CodevisorServerClienting,
    debounce: Duration = .milliseconds(300),
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.client = client
    self.debounce = debounce
    self.sleep = sleep
  }

  public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  public func sections(hiding blockedPublishers: [String]) -> [PluginCatalogSection] {
    PluginCatalogSection.sections(from: entries, searching: isSearching, hiding: Set(blockedPublishers))
  }

  public func load() async {
    await fetch(query, generation: nextGeneration())
  }

  public func search(_ text: String) {
    guard text != query else { return }

    query = text
    searchTask?.cancel()
    let generation = nextGeneration()
    searchTask = Task { [weak self, sleep, debounce] in
      do { try await sleep(debounce) } catch { return }
      guard !Task.isCancelled else { return }
      await self?.fetch(text, generation: generation)
    }
  }

  public func settleSearch() async {
    await searchTask?.value
  }

  public func install(
    _ entry: ServerPluginCatalogEntry,
    values: [String: ServerConfigFieldValue],
    access: PluginAccessController
  ) async throws -> ServerMcpServer {
    installing.insert(entry.id)
    defer { installing.remove(entry.id) }

    let subject = PluginModerationSubject(catalogEntry: entry)
    try await access.requireEligible(subject)
    let metadata = PluginConsentMetadata(entry, ageRating: access.ageRating(for: subject))
    try await access.recordConsent(subject, metadata: metadata)
    return try await client.installCatalogPlugin(id: entry.id, values: values)
  }

  private func nextGeneration() -> Int {
    generation += 1
    return generation
  }

  private func fetch(_ text: String, generation: Int) async {
    isLoading = true
    do {
      let found = try await client.listPluginCatalog(query: text)
      guard generation == self.generation else { return }
      entries = found
      errorMessage = nil
    } catch {
      guard generation == self.generation, !isTaskCancellation(error) else { return }
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
    isLoading = false
  }
}
