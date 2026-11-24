import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorFiles {
  let workspace: Workspace
  let media: WorkspaceInspectorMediaModel
  let environment: AppEnvironment
  let store: SessionStore
  let identity: HandlerIdentity

  func opener(lightbox: FileLightbox?) -> FileOpener? {
    guard let lightbox else { return nil }

    var opener = FileOpener(identity: identity, site: site, lightbox: lightbox, openInTab: openInTab)
    opener.transfers = MacFileTransfers.transfers
    opener.presentMenu = FileMenuPopup.present
    opener.siblings = { [media] _ in media.media.map { ViewableFile(Self.file(for: $0)) } }
    return opener
  }

  static func file(for item: ServerWorkspaceMedia) -> PreviewFile {
    PreviewFile(
      source: .attachment(fileId: item.attachment.fileId),
      name: item.attachment.name,
      mimeType: item.attachment.mimeType,
      kind: item.isVideo ? .file : .image
    )
  }

  private var site: FileOpener.Site {
    FileOpener.Site(
      rootPath: workspace.rootDirectory ?? "/", machineId: workspace.serverId,
      client: environment.machines.client(for: workspace.serverId))
  }

  private var openInTab: (@MainActor (String) -> Bool)? {
    guard !WorkspaceLayoutPolicy.isTabless(workspace, environment: environment) else { return nil }
    return { [store, workspace] target in
      store.inspectorOpenRequest = WorkspaceInspectorOpenRequest(workspaceId: workspace.id, destination: .file(target))
      return true
    }
  }
}
