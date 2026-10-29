import CodevisorCore
import SwiftUI

public struct McpAccountButton: View {
  @Environment(AppEnvironment.self) private var environment
  private let entry: McpFleetEntry
  private let model: McpGlobalModel
  private let onSignIn: (_ machineId: String) -> Void
  @State private var isSigningOut = false

  public init(
    entry: McpFleetEntry, model: McpGlobalModel,
    onSignIn: @escaping (_ machineId: String) -> Void
  ) {
    self.entry = entry
    self.model = model
    self.onSignIn = onSignIn
  }

  public static func isShown(for entry: McpFleetEntry, model: McpGlobalModel, in environment: AppEnvironment) -> Bool {
    let summary = McpFleetSummary(entry: entry, rows: model.rows(for: entry, in: environment))
    return summary.needsSignIn || summary.isSignedIn
  }

  public var body: some View {
    if summary.needsSignIn, let machineId = preferredMachineId {
      Button("Sign In…") { onSignIn(machineId) }
    } else if summary.isSignedIn {
      Button("Sign Out") { Task { await signOut() } }
        .disabled(isSigningOut)
    }
  }

  private var summary: McpFleetSummary {
    McpFleetSummary(entry: entry, rows: model.rows(for: entry, in: environment))
  }

  private var preferredMachineId: String? {
    entry.machineId(preferring: CodevisorMachine.local.id)
  }

  private func signOut() async {
    isSigningOut = true
    defer { isSigningOut = false }
    await model.disconnect(entry, in: environment)
  }
}
