import CodevisorCore
import SwiftUI

public extension View {
  func pluginBlockConfirmation(subject: PluginModerationSubject, isPresented: Binding<Bool>) -> some View {
    modifier(PluginBlockConfirmation(subject: subject, confirmingBlock: isPresented))
  }
}

private struct PluginBlockConfirmation: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  let subject: PluginModerationSubject
  @Binding var confirmingBlock: Bool
  @State private var errorMessage: String?

  private var isBlocked: Bool { environment.pluginAccess.isBlocked(publisher: subject.publisher) }

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        isBlocked ? "Unblock \(subject.publisher)?" : "Block \(subject.publisher)?",
        isPresented: $confirmingBlock, titleVisibility: .visible
      ) {
        Button(isBlocked ? "Unblock Publisher" : "Block Publisher", role: isBlocked ? nil : .destructive) {
          Task { await toggleBlock() }
        }
      } message: {
        Text(isBlocked ? "Its plugins can open again." : "Its plugins won’t open on iOS and are hidden from Browse.")
      }
      .alert(
        "Couldn’t update this publisher",
        isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK", role: .cancel) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
  }

  private func toggleBlock() async {
    do {
      try await environment.pluginAccess.setPublisherBlocked(subject.publisher, blocked: !isBlocked)
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
