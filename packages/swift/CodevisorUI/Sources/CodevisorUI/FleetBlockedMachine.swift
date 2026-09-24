import CodevisorCore
import SwiftUI

/// The fleet plane a blocked row belongs to — the only thing the shared
/// details popover needs in order to offer the right recovery.
public enum FleetPlane: String, Sendable {
  case harnesses
  case mcps
  case skills
  case plugins

  @MainActor
  func reconcile(_ client: any CodevisorServerClienting) async throws {
    switch self {
    case .harnesses: _ = try await client.reconcileHarnessesSync()
    case .mcps: _ = try await client.reconcileMcpsSync()
    case .skills: _ = try await client.reconcileSkillsSync()
    case .plugins: _ = try await client.reconcilePluginsSync()
    }
  }
}

/// A machine that couldn't converge on one entry, opened from its row.
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
  /// The failure text as the machine reported it, with the one recovery the
  /// client can offer: another sync pass. A popover on macOS, an alert on
  /// iOS. Shared by all four fleet pages so a blocked MCP explains itself
  /// exactly the way a blocked harness does.
  func fleetBlockedDetails(item: Binding<FleetBlockedMachine?>) -> some View {
    modifier(FleetBlockedDetailsModifier(item: item))
  }
}

private struct FleetBlockedDetailsModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
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
            Text(retryError).font(.callout).foregroundStyle(theme.textSecondary)
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
