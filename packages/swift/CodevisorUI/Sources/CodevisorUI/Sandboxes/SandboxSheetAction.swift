import SwiftUI

extension EnvironmentValues {
  @Entry var sandboxSheetCancel: SandboxSheetAction?
  @Entry var sandboxSheetBack: SandboxSheetAction?
  @Entry var sandboxSheetIsCovered = false
}

struct SandboxSheetAction: Sendable {
  private let handler: @MainActor @Sendable () -> Void

  init(_ handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }

  @MainActor func callAsFunction() { handler() }
}
