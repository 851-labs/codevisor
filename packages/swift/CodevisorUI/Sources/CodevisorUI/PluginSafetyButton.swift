import CodevisorCore
import SwiftUI

public struct PluginSafetyButton: View {
  let subject: PluginModerationSubject
  @State private var reporting = false
  @State private var confirmingBlock = false

  public init(subject: PluginModerationSubject) {
    self.subject = subject
  }

  public var body: some View {
    Menu {
      PluginSafetyMenuItems(
        subject: subject, onReport: { reporting = true }, onBlock: { confirmingBlock = true })
    } label: {
      Image(systemName: "flag")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Report or block \(subject.name)")
    .help("Report or Block")
    .pluginSafetyActions(subject: subject, reporting: $reporting, confirmingBlock: $confirmingBlock)
  }
}

public struct PluginSafetyMenuItems: View {
  @Environment(AppEnvironment.self) private var environment
  let subject: PluginModerationSubject
  let onReport: () -> Void
  let onBlock: () -> Void

  public init(subject: PluginModerationSubject, onReport: @escaping () -> Void, onBlock: @escaping () -> Void) {
    self.subject = subject
    self.onReport = onReport
    self.onBlock = onBlock
  }

  public var body: some View {
    Button("Report…", action: onReport)
    Button(isBlocked ? "Unblock Publisher…" : "Block Publisher…", action: onBlock)
  }

  private var isBlocked: Bool { environment.pluginAccess.isBlocked(publisher: subject.publisher) }
}

public extension View {
  func pluginSafetyActions(
    subject: PluginModerationSubject, reporting: Binding<Bool>, confirmingBlock: Binding<Bool>
  ) -> some View {
    modifier(PluginSafetyActions(subject: subject, reporting: reporting, confirmingBlock: confirmingBlock))
  }
}

private struct PluginSafetyActions: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  let subject: PluginModerationSubject
  @Binding var reporting: Bool
  @Binding var confirmingBlock: Bool
  @State private var errorMessage: String?

  private var isBlocked: Bool { environment.pluginAccess.isBlocked(publisher: subject.publisher) }

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: $reporting) {
        PluginReportSheet(subject: subject).environment(environment)
      }
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
