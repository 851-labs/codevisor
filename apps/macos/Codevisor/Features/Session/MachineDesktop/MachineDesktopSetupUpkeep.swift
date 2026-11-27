import CodevisorCore
import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopSetupUpkeep: ViewModifier {
  private static let lookEvery: Duration = .seconds(3)
  private static let looks = 10

  let machineId: String
  let machineName: String
  let view: UUID
  @Bindable var store: StoreOf<MachineDesktopSetup>
  @Environment(AppEnvironment.self) private var environment

  func body(content: Content) -> some View {
    content
      .task { store.send(.task) }
      .onChange(of: machineName, initial: true) { store.send(.machineRenamed(machineName)) }
      .onDisappear { store.send(.askerLeft(view)) }
      .onChange(of: sharesDesktop) { store.send(.machineChanged) }
      .task(id: awaitsItsDesktop) { await waitForTheDesktop() }
      .confirmationDialog(dialog)
  }

  private var sharesDesktop: Bool { environment.machines.desktopMachine(for: machineId) != nil }

  private var awaitsItsDesktop: Bool { store.awaitsItsDesktop && !sharesDesktop }

  private typealias Question = MachineDesktopSetup.Confirmation

  private var dialog: Binding<Store<ConfirmationDialogState<Question>, Question>?> {
    guard store.asker == view else { return .constant(nil) }

    return $store.scope(state: \.confirmation, action: \.confirmation)
  }

  private func waitForTheDesktop() async {
    guard awaitsItsDesktop else { return }

    for _ in 0..<Self.looks {
      guard (try? await Task.sleep(for: Self.lookEvery)) != nil else { return }
      await environment.machines.refreshStatus(for: machineId)
      if sharesDesktop { return }
    }
    store.send(.desktopNeverAppeared)
  }
}
