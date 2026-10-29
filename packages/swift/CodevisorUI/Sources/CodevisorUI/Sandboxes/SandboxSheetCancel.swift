import SwiftUI

extension EnvironmentValues {
  @Entry var sandboxSheetCancel: SandboxSheetCancel?
}

struct SandboxSheetCancel: Sendable {
  private let handler: @MainActor @Sendable () -> Void

  init(_ handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }

  @MainActor func callAsFunction() { handler() }
}
