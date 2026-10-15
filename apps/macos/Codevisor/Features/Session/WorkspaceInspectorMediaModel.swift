import CodevisorClient
import Foundation
import Observation

enum WorkspaceInspectorTab: String, Codable, CaseIterable, Identifiable {
  case info, photos, links

  var id: Self { self }

  var title: String {
    switch self {
    case .info: "Info"
    case .photos: "Photos"
    case .links: "Links"
    }
  }
}

@MainActor
@Observable
final class WorkspaceInspectorMediaModel {
  enum Phase: Equatable {
    case idle, loading, loaded
    case failed(String)
  }

  private static let photoPageSize = 60
  private static let linkPageSize = 100

  private(set) var photos: [ServerWorkspacePhoto] = []
  private(set) var links: [ServerWorkspaceLink] = []
  private(set) var photosPhase = Phase.idle
  private(set) var linksPhase = Phase.idle
  @ObservationIgnored private var photosNextBefore: String?
  @ObservationIgnored private var linksNextBefore: String?
  @ObservationIgnored private var workspaceId: UUID?
  @ObservationIgnored private var client: (any CodevisorServerClienting)?

  func reload(_ tab: WorkspaceInspectorTab, workspaceId: UUID, client: any CodevisorServerClienting) async {
    if self.workspaceId != workspaceId {
      self.workspaceId = workspaceId
      photos = []
      links = []
      photosPhase = .idle
      linksPhase = .idle
    }
    self.client = client
    switch tab {
    case .info: break
    case .photos: await loadPhotos(before: nil)
    case .links: await loadLinks(before: nil)
    }
  }

  func loadMorePhotos() async {
    guard photosPhase == .loaded, let next = photosNextBefore else { return }
    await loadPhotos(before: next)
  }

  func loadMoreLinks() async {
    guard linksPhase == .loaded, let next = linksNextBefore else { return }
    await loadLinks(before: next)
  }

  private func loadPhotos(before: String?) async {
    guard let client, let workspaceId else { return }
    photosPhase = .loading
    do {
      let page = try await client.workspacePhotos(
        workspaceId: workspaceId, before: before, limit: Self.photoPageSize)
      guard workspaceId == self.workspaceId else { return }
      photos = before == nil ? page.photos : Self.appending(page.photos, to: photos)
      photosNextBefore = page.nextBefore
      photosPhase = .loaded
    } catch {
      guard workspaceId == self.workspaceId, !Task.isCancelled else { return }
      photosPhase = .failed(error.localizedDescription)
    }
  }

  private func loadLinks(before: String?) async {
    guard let client, let workspaceId else { return }
    linksPhase = .loading
    do {
      let page = try await client.workspaceLinks(
        workspaceId: workspaceId, before: before, limit: Self.linkPageSize)
      guard workspaceId == self.workspaceId else { return }
      links = before == nil ? page.links : Self.appending(page.links, to: links)
      linksNextBefore = page.nextBefore
      linksPhase = .loaded
    } catch {
      guard workspaceId == self.workspaceId, !Task.isCancelled else { return }
      linksPhase = .failed(error.localizedDescription)
    }
  }

  private static func appending<Element: Identifiable>(_ page: [Element], to existing: [Element]) -> [Element] {
    let known = Set(existing.map(\.id))
    return existing + page.filter { !known.contains($0.id) }
  }
}
