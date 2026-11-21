import CodevisorClient
import CodevisorCore
import SwiftUI

struct FirstRunQuestionSheet: View {
  let folders: FirstRunFolderAccess?
  let claudeCodeLogin: FirstRunClaudeCodeLogin?

  var body: some View {
    if let folders, let folder = folders.current {
      FolderAccessSheet(folder: folder, folders: folders)
    } else if let claudeCodeLogin {
      switch claudeCodeLogin.stage {
      case let .asking(question): ClaudeCodeLoginSheet(question: question, login: claudeCodeLogin)
      case .signingIn:
        HarnessSignInSheet(serverId: CodevisorMachine.local.id, harnessId: "claude-code", startsSignIn: true)
      case nil: EmptyView()
      }
    }
  }
}
