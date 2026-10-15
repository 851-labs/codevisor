import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

struct ComposerMachineMenu: UIViewRepresentable {
  let machineName: String
  let machines: [CodevisorMachine]
  let selectedServerId: String
  let readyMachineIds: Set<String>
  let onMachine: (CodevisorMachine) -> Void
  let onManageMachines: () -> Void

  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    button.showsMenuAsPrimaryAction = true
    button.preferredMenuElementOrder = .fixed
    button.accessibilityLabel = "Machine"
    button.accessibilityIdentifier = "newChat.machinePicker"
    return button
  }

  func updateUIView(_ button: UIButton, context: Context) {
    button.isEnabled = context.environment.isEnabled
    button.accessibilityValue = machineName
    let choices = machines.map { machine in
      UIAction(
        title: machine.name,
        image: UIImage(systemName: machine.icon.systemImage),
        attributes: readyMachineIds.contains(machine.id) ? [] : .disabled,
        state: machine.id == selectedServerId ? .on : .off
      ) { _ in
        onMachine(machine)
      }
    }
    let manage = UIAction(
      title: "Manage Machines…",
      image: UIImage(systemName: "gearshape")
    ) { _ in
      onManageMachines()
    }
    let managementMenu = UIMenu(options: .displayInline, children: [manage])
    let preferences = UIMenuDisplayPreferences()
    preferences.maximumNumberOfTitleLines = 1
    managementMenu.displayPreferences = preferences
    button.menu = UIMenu(children: [
      managementMenu,
      UIMenu(options: [.displayInline, .singleSelection], children: choices),
    ])
  }
}
