import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopMenu: View {
  let store: StoreOf<MachineDesktopSetup>
  let view: UUID

  var body: some View {
    if let removal = store.removal {
      Menu {
        Button(title(removal), role: .destructive, action: askToRemove)
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 20, height: 14)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .foregroundStyle(.secondary)
      .help("Desktop options")
      .accessibilityLabel("Desktop options")
      .accessibilityIdentifier("machineDesktop.menu")
    }
  }

  private func askToRemove() {
    store.send(.interacted(from: view))
    store.send(.removeButtonTapped)
  }

  private func title(_ removal: MachineDesktopSetup.Confirmation) -> String {
    removal == .stopSharing ? "Stop Sharing Desktop…" : "Remove Desktop…"
  }
}
