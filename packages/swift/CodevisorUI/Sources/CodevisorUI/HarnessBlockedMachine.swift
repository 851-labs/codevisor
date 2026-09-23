import CodevisorCore
import SwiftUI

/// A machine that couldn't converge on a harness, chosen from the row's menu.
struct HarnessBlockedMachine: Identifiable, Equatable {
  let machineId: String
  let machineName: String
  let harnessName: String
  let reason: String
  var id: String { machineId }
  var title: String { "\(harnessName) on \(machineName)" }
}

extension View {
  /// The failure text as the machine reported it, with the one recovery the
  /// client can offer: another sync pass. A popover on macOS, an alert on iOS.
  func harnessBlockedDetails(item: Binding<HarnessBlockedMachine?>) -> some View {
    modifier(HarnessBlockedDetailsModifier(item: item))
  }
}

private struct HarnessBlockedDetailsModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Binding var item: HarnessBlockedMachine?
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
      content.alert(item?.title ?? "", isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } })) {
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

  private func retry(_ blocked: HarnessBlockedMachine) async {
    isRetrying = true
    retryError = nil
    defer { isRetrying = false }
    do {
      _ = try await environment.machines.client(for: blocked.machineId).reconcileHarnessesSync()
      environment.harnessCatalogDidChange(onServer: blocked.machineId)
      item = nil
    } catch {
      retryError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
