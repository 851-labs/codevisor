import CodevisorCore
import SwiftUI

public enum FleetPlane: String, Sendable {
  case harnesses
  case mcps
  case plugins

  @MainActor
  func reconcile(_ client: any CodevisorServerClienting) async throws {
    switch self {
    case .harnesses: _ = try await client.reconcileHarnessesSync()
    case .mcps: _ = try await client.reconcileMcpsSync()
    case .plugins: _ = try await client.reconcilePluginsSync()
    }
  }
}

public struct FleetBlockedMachine: Identifiable, Equatable {
  public let plane: FleetPlane
  public let machineId: String
  public let machineName: String
  public let entryName: String
  public let reason: String
  public var id: String { "\(plane.rawValue)|\(machineId)|\(entryName)" }
  public var title: String { "\(entryName) on \(machineName)" }

  public init(
    plane: FleetPlane, machineId: String, machineName: String, entryName: String, reason: String
  ) {
    self.plane = plane
    self.machineId = machineId
    self.machineName = machineName
    self.entryName = entryName
    self.reason = reason
  }
}

public extension View {
  func fleetBlockedDetails(item: Binding<FleetBlockedMachine?>) -> some View {
    modifier(FleetBlockedDetailsModifier(item: item))
  }
}

private struct FleetBlockedDetailsModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var item: FleetBlockedMachine?
  @State private var isRetrying = false
  @State private var retryError: String?

  func body(content: Content) -> some View {
    #if os(macOS)
      content.popover(item: $item, arrowEdge: .bottom) { blocked in
        VStack(alignment: .leading, spacing: 10) {
          Text(blocked.title).font(.headline)
          ScrollView {
            Text(blocked.reason)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 160)
          if let retryError {
            Text(retryError).font(.callout).foregroundStyle(.secondary)
          }
          HStack {
            Button("Copy") { PlatformPasteboard.copy(blocked.reason) }
            Spacer()
            if isRetrying { ProgressView().controlSize(.small) }
            Button("Retry") { Task { await retry(blocked) } }.disabled(isRetrying)
          }
        }
        .padding(16)
        .frame(width: 380)
      }
    #else
      content.alert(
        item?.title ?? "",
        isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } })
      ) {
        if let blocked = item {
          Button("Retry") { Task { await retry(blocked) } }
          Button("Copy") { PlatformPasteboard.copy(blocked.reason) }
        }
        Button("OK", role: .cancel) {}
      } message: {
        if let blocked = item {
          Text(retryError.map { "\(blocked.reason)\n\n\($0)" } ?? blocked.reason)
        }
      }
    #endif
  }

  private func retry(_ blocked: FleetBlockedMachine) async {
    isRetrying = true
    retryError = nil
    defer { isRetrying = false }
    do {
      try await blocked.plane.reconcile(environment.machines.client(for: blocked.machineId))
      if blocked.plane == .harnesses {
        environment.harnessCatalogDidChange(onServer: blocked.machineId)
      }
      item = nil
    } catch {
      retryError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
