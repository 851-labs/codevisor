import CodevisorClient
import Observation

@MainActor
@Observable
public final class FirstRunFolderAccess {
  public typealias Permission = @MainActor (ServerFirstRunFolder) -> FirstRunFolderPermission

  public private(set) var asking: [ServerFirstRunFolder] = []
  public private(set) var answeringId: String?
  public private(set) var answered = 0

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let permission: Permission
  @ObservationIgnored private let feed: FirstRunStatusFeed
  @ObservationIgnored private var settledIds: Set<String> = []
  @ObservationIgnored private var isFollowing = false

  public init(client: any CodevisorServerClienting, permission: @escaping Permission) {
    self.client = client
    self.permission = permission
    feed = FirstRunStatusFeed(client: client)
  }

  public var current: ServerFirstRunFolder? { asking.first }

  public var isAsking: Bool { !asking.isEmpty }

  public func follow() async {
    guard !isFollowing, await client.waitUntilConnected() else { return }
    isFollowing = true
    defer { feed.stop() }

    var seen: ServerFirstRunStatus?
    while !Task.isCancelled {
      guard let status = try? await feed.status(where: { $0 != seen }) else { return }
      seen = status
      await show(status.foldersToAsk)
      if status.isFinal, status.foldersToAsk.isEmpty { return }
    }
  }

  public func answer(_ folder: ServerFirstRunFolder, allow: Bool) async {
    answeringId = folder.id
    guard await send(allow ? .allow : .decline, for: folder) else {
      giveUp(on: folder)
      return
    }
  }

  private func show(_ waiting: [ServerFirstRunFolder]) async {
    let waitingIds = Set(waiting.map(\.id))
    let stillAsked = asking.filter { waitingIds.contains($0.id) }
    answered += asking.count - stillAsked.count
    asking = stillAsked
    if let answeringId, !waitingIds.contains(answeringId) { self.answeringId = nil }
    let askingIds = Set(asking.map(\.id))
    for folder in waiting where !settledIds.contains(folder.id) && !askingIds.contains(folder.id) {
      await place(folder)
    }
  }

  private func place(_ folder: ServerFirstRunFolder) async {
    switch permission(folder) {
    case .undetermined: asking.append(folder)
    case .allowed: await settle(folder, with: .allow)
    case .denied: await settle(folder, with: .decline)
    }
  }

  private func settle(_ folder: ServerFirstRunFolder, with access: ServerFirstRunFolderAnswer.Access) async {
    settledIds.insert(folder.id)
    _ = await send(access, for: folder)
  }

  private func send(_ access: ServerFirstRunFolderAnswer.Access, for folder: ServerFirstRunFolder) async -> Bool {
    (try? await client.answerFirstRunFolder(id: folder.id, access: access)) != nil
  }

  private func giveUp(on folder: ServerFirstRunFolder) {
    settledIds.insert(folder.id)
    answeringId = nil
    asking.removeAll { $0.id == folder.id }
    answered += 1
  }
}
