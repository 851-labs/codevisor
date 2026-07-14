import SwiftUI
import CodevisorCore

/// The compact, always-available machine selector in the window toolbar.
/// Its glyph mirrors the selected machine's saved appearance and inherits the
/// active theme's semantic foreground color.
struct MachinePickerToolbarMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    @Environment(\.theme) private var theme
    @State private var showingAdd = false
    @State private var addError: String?

    private var machines: MachineController { environment.machines }
    private var selectedMachine: CodevisorMachine { machines.selectedMachine }

    var body: some View {
        Menu {
            ForEach(machines.machines) { machine in
                Toggle(isOn: Binding(
                    get: { machine.id == machines.selectedMachineId },
                    set: { isOn in
                        guard isOn else { return }
                        machines.selectMachine(machine.id)
                    }
                )) {
                    Label {
                        Text(machine.name)
                    } icon: {
                        MenuSymbolIcon(systemName: machine.resolvedAppearance.symbolName)
                    }
                }
            }

            Divider()

            Button("Add Remote Machine…") {
                showingAdd = true
            }

            Button("Manage Machines…") {
                SettingsRouter.shared.selectedTab = .machines
                openSettings()
            }
        } label: {
            Image(systemName: selectedMachine.resolvedAppearance.symbolName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.textPrimary)
                // SF Symbols have different intrinsic widths. Give every
                // machine glyph the same centered slot so the menu doesn't
                // effectively leading-align wider symbols.
                .frame(width: 20, height: 20)
                // A hidden macOS menu indicator still reserves trailing
                // space, leaving that slot two points left of the toolbar
                // button's visual center.
                .offset(x: 2)
        }
        .menuIndicator(.hidden)
        .help("Switch machine — \(selectedMachine.name)")
        .accessibilityLabel("Machine: \(selectedMachine.name)")
        .sheet(isPresented: $showingAdd) {
            RemoteMachineSheet { host, name, token in
                do {
                    try machines.addRemote(host: host, name: name, token: token)
                } catch {
                    addError = ErrorReporter.userFacingMessage(for: error)
                }
            }
        }
        .alert(
            "Couldn't Add the Machine",
            isPresented: Binding(
                get: { addError != nil },
                set: { if !$0 { addError = nil } }
            ),
            presenting: addError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}
