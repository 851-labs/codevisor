import CodevisorClient
import CodevisorCore
import SwiftUI

struct ClaudeCodeLoginSheet: View {
  let question: ServerFirstRunClaudeCodeLogin
  let login: FirstRunClaudeCodeLogin

  var body: some View {
    VStack(spacing: 20) {
      ClaudeCodeLoginHeader(email: question.email)
      VStack(spacing: 12) {
        HStack {
          Button("Not Now") { answer(.notNow) }
            .keyboardShortcut(.cancelAction)
          Spacer()
          Button("Sign In…") { answer(.signIn) }
          Button("Transfer") { answer(.transfer) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .disabled(login.isAnswering)
        ClaudeCodeLoginStatus(login: login)
      }
    }
    .padding(24)
    .frame(width: 420)
    .animation(.snappy(duration: 0.2), value: login.isAnswering)
    .interactiveDismissDisabled()
  }

  private func answer(_ choice: ServerFirstRunClaudeCodeLoginAnswer.Choice) {
    Task { await login.answer(choice) }
  }
}
