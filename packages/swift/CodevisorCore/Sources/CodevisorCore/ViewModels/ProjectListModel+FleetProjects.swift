import Foundation

extension ProjectListModel {
  public func removeAllRecords(serverId: String) {
    navigationStore?.forget(machineId: serverId)
  }

  @discardableResult
  public func addProject(
    folderURL: URL,
    serverId: String,
    client: any CodevisorServerClienting
  ) async -> Project {
    let local = addProject(folderURL: folderURL, serverId: serverId)
    do {
      let probed = try await client.upsertProject(local).project(serverId: serverId)
      var merged = local
      merged.locations = probed.locations
      merged.repoUrl = probed.repoUrl
      merged.repoKey = probed.repoKey
      return merged
    } catch {
      Log.sync.error(
        "Couldn't probe project \(local.id.uuidString, privacy: .public) yet: \(String(describing: error), privacy: .public)"
      )
      return local
    }
  }
}
