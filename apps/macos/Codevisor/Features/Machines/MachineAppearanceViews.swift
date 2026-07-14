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
                Button {
                    machines.selectMachine(machine.id)
                } label: {
                    HStack {
                        Label(machine.name, systemImage: machine.resolvedAppearance.symbolName)
                        if machine.id == machines.selectedMachineId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                showingAdd = true
            } label: {
                Label("Add Remote Machine…", systemImage: "plus")
            }

            Button {
                SettingsRouter.shared.selectedTab = .machines
                openSettings()
            } label: {
                Label("Manage Machines…", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: selectedMachine.resolvedAppearance.symbolName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.textPrimary)
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

/// Sheet for assigning an SF Symbol to one machine.
struct MachineAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var symbolName: String
    @State private var choosingIcon = false

    let machine: CodevisorMachine
    let onSave: (MachineAppearance) -> Void

    init(machine: CodevisorMachine, onSave: @escaping (MachineAppearance) -> Void) {
        self.machine = machine
        self.onSave = onSave
        let appearance = machine.resolvedAppearance
        _symbolName = State(initialValue: appearance.symbolName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Customize \(machine.name)")
                .font(.headline)

            HStack(spacing: 16) {
                Image(systemName: symbolName)
                    .font(.system(size: 32))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Button("Choose Icon…") {
                    choosingIcon = true
                }
                .settingsActionTint(theme)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                Button("Save") {
                    onSave(MachineAppearance(symbolName: symbolName))
                    dismiss()
                }
                .settingsActionTint(theme)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .sheet(isPresented: $choosingIcon) {
            IconPickerView(currentSymbol: symbolName) { symbolName = $0 }
        }
    }
}
