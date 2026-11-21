import CodevisorCore
import SwiftUI

struct FirstRunQuestionsGate: ViewModifier {
  let folders: FirstRunFolderAccess?
  let claudeCodeLogin: FirstRunClaudeCodeLogin?

  func body(content: Content) -> some View {
    content.sheet(isPresented: isPresented) {
      FirstRunQuestionSheet(folders: folders, claudeCodeLogin: claudeCodeLogin)
    }
  }

  private var isPresented: Binding<Bool> {
    Binding {
      folders?.isAsking == true || claudeCodeLogin?.isWaitingOnUser == true
    } set: { isPresented in
      guard !isPresented else { return }
      claudeCodeLogin?.finishSigningIn()
    }
  }
}
