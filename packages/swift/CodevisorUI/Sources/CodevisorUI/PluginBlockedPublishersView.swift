import CodevisorCore
import SwiftUI

public struct PluginBlockedPublishersView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var errorMessage: String?
  @State private var working = false
  public init() {}

  public var body: some View {
    List {
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      if environment.pluginAccess.blockedPublishers.isEmpty {
        Text("No blocked publishers.").foregroundStyle(.secondary)
      }
      ForEach(environment.pluginAccess.blockedPublishers, id: \.self) { publisher in
        HStack {
          Text(publisher)
          Spacer()
          Button("Unblock") {
            Task {
              working = true
              defer { working = false }
              do {
                try await environment.pluginAccess.setPublisherBlocked(publisher, blocked: false)
                errorMessage = nil
              } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
            }
          }
          .disabled(working)
        }
      }
    }
    .navigationTitle("Blocked Publishers")
    .task {
      do { _ = try await environment.pluginAccess.snapshot() } catch {
        errorMessage = ErrorReporter.userFacingMessage(for: error)
      }
    }
  }
}
