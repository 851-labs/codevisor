import CodevisorClient
import Foundation
import Observation

enum WorkspaceInspectorTab: String, Codable, CaseIterable, Identifiable {
  case info, machine, media = "photos", links, files

  var id: Self { self }

  var title: String {
    switch self {
    case .info: "Info"
    case .machine: "Machine"
    case .media: "Media"
    case .links: "Links"
    case .files: "Files"
    }
  }

  var systemImage: String {
    switch self {
    case .info: "info.circle"
    case .machine: "desktopcomputer"
    case .media: "photo.on.rectangle"
    case .links: "link"
    case .files: "folder"
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

  private static let mediaPageSize = 60
  private static let linkPageSize = 100

  private(set) var media: [ServerWorkspaceMedia] = []
  private(set) var links: [ServerWorkspaceLink] = []
  private(set) var mediaPhase = Phase.idle
  private(set) var linksPhase = Phase.idle
  private var mediaNextBefore: String?
  private(set) var linksNextBefore: String?
  @ObservationIgnored private var workspaceId: UUID?
  @ObservationIgnored private var client: (any CodevisorServerClienting)?

  var hasMoreLinks: Bool { linksNextBefore != nil }

  func reload(_ tab: WorkspaceInspectorTab, workspaceId: UUID, client: any CodevisorServerClienting) async {
    if self.workspaceId != workspaceId {
      self.workspaceId = workspaceId
      media = []
      links = []
      mediaPhase = .idle
      linksPhase = .idle
    }
    self.client = client
    switch tab {
    case .info, .machine: break
    case .media: await loadMedia(before: nil)
    case .links: await loadLinks(before: nil)
    case .files: break
    }
  }

  func loadMoreMedia() async {
    guard mediaPhase == .loaded, let next = mediaNextBefore else { return }
    await loadMedia(before: next)
  }

  func loadMoreLinks() async {
    guard linksPhase == .loaded, let next = linksNextBefore else { return }
    await loadLinks(before: next)
  }

  private func loadMedia(before: String?) async {
    guard let client, let workspaceId else { return }
    mediaPhase = .loading
    do {
      let page = try await client.workspaceMedia(
        workspaceId: workspaceId, before: before, limit: Self.mediaPageSize)
      guard workspaceId == self.workspaceId else { return }
      (media, mediaNextBefore) =
        before == nil
        ? Self.refreshing(media, cursor: mediaNextBefore, with: page.media, nextBefore: page.nextBefore)
        : (Self.appending(page.media, to: media), page.nextBefore)
      mediaPhase = .loaded
    } catch {
      guard workspaceId == self.workspaceId, !Task.isCancelled else { return }
      mediaPhase = .failed(error.localizedDescription)
    }
  }

  private func loadLinks(before: String?) async {
    guard let client, let workspaceId else { return }
    linksPhase = .loading
    do {
      let page = try await client.workspaceLinks(
        workspaceId: workspaceId, before: before, limit: Self.linkPageSize)
      guard workspaceId == self.workspaceId else { return }
      (links, linksNextBefore) =
        before == nil
        ? Self.refreshing(links, cursor: linksNextBefore, with: page.links, nextBefore: page.nextBefore)
        : (Self.appending(page.links, to: links), page.nextBefore)
      linksPhase = .loaded
    } catch {
      guard workspaceId == self.workspaceId, !Task.isCancelled else { return }
      linksPhase = .failed(error.localizedDescription)
    }
  }

  private static func refreshing<Element: Identifiable>(
    _ existing: [Element], cursor: String?, with page: [Element], nextBefore: String?
  ) -> ([Element], String?) {
    let fresh = Set(page.map(\.id))
    let older = existing.filter { !fresh.contains($0.id) }
    return older.isEmpty ? (page, nextBefore) : (page + older, cursor)
  }

  private static func appending<Element: Identifiable>(_ page: [Element], to existing: [Element]) -> [Element] {
    let known = Set(existing.map(\.id))
    return existing + page.filter { !known.contains($0.id) }
  }
}
