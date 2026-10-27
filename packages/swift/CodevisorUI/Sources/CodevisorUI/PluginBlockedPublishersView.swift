import CodevisorCore
import SwiftUI

public struct PluginBlockedPublishersView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var errorMessage: String?
  @State private var working = false

  public init() {}

  public var body: some View {
    Form {
      Section {
        if environment.pluginAccess.blockedPublishers.isEmpty {
          Text("No blocked publishers").foregroundStyle(.secondary)
        }
        ForEach(environment.pluginAccess.blockedPublishers, id: \.self) { publisher in
          LabeledContent(publisher) {
            Button("Unblock") { Task { await unblock(publisher) } }
              .disabled(working)
          }
        }
      } footer: {
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Blocked Publishers")
    .task { await load() }
  }

  private func load() async {
    do {
      try await environment.pluginAccess.refresh()
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func unblock(_ publisher: String) async {
    working = true
    defer { working = false }
    do {
      try await environment.pluginAccess.setPublisherBlocked(publisher, blocked: false)
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
