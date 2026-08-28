import CodevisorCore
import SwiftUI

/// The installation step in the harness-management navigation flow.
/// The title identifies the harness, the form chooses its install method,
/// and the trailing confirmation action starts the installation.
struct HarnessInstallScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let harness: ServerHarness
    let machine: CodevisorMachine
    let onStarted: (ServerHarnessOperationStarted, String) -> Void

    @State private var selectedMethodId: String
    @State private var isStarting = false
    @State private var errorMessage: String?

    init(
        harness: ServerHarness,
        machine: CodevisorMachine,
        onStarted: @escaping (ServerHarnessOperationStarted, String) -> Void
    ) {
        self.harness = harness
        self.machine = machine
        self.onStarted = onStarted
        let methods = (harness.installMethods ?? []).filter(\.available)
        _selectedMethodId = State(
            initialValue: methods.first(where: \.recommended)?.id ?? methods.first?.id ?? ""
        )
    }

    private var methods: [ServerHarnessInstallMethod] {
        (harness.installMethods ?? []).filter(\.available)
    }

    private var selectedMethod: ServerHarnessInstallMethod? {
        methods.first { $0.id == selectedMethodId }
    }

    var body: some View {
        Form {
            if methods.isEmpty {
                Section {
                    Label("Installation Unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker("Install Using", selection: $selectedMethodId) {
                        ForEach(methods, id: \.id) { method in
                            Text(method.label).tag(method.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .disabled(isStarting)
        .navigationTitle(harness.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isStarting)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await install() }
                } label: {
                    ZStack {
                        Text("Install")
                            .opacity(isStarting ? 0 : 1)
                        if isStarting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(selectedMethod == nil || isStarting)
                .accessibilityLabel(isStarting ? "Installing" : "Install")
            }
        }
        .interactiveDismissDisabled(isStarting)
        .alert(
            "Couldn’t Install \(harness.name)",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The installation didn’t finish. Check the install method and try again.")
        }
    }

    private func install() async {
        guard let selectedMethod else { return }
        isStarting = true
        errorMessage = nil
        do {
            let client = environment.machines.client(for: machine.id)
            let started =
                try await client
                .installHarness(id: harness.id, methodId: selectedMethod.id)
            onStarted(started, selectedMethod.id)

            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
                guard
                    let current = try await client.listHarnessesWithLifecycle()
                        .first(where: { $0.id == harness.id })
                else {
                    throw HarnessInstallStatusError.harnessUnavailable
                }

                switch current.lifecycle?.phase {
                case "installing":
                    continue
                case "failed":
                    throw HarnessInstallStatusError.failed(current.lifecycle?.error)
                case "idle", nil:
                    environment.harnessCatalogDidChange(onServer: machine.id)
                    dismiss()
                    return
                default:
                    continue
                }
            }
        } catch is CancellationError {
            isStarting = false
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
            isStarting = false
        }
    }
}

private enum HarnessInstallStatusError: LocalizedError {
    case failed(String?)
    case harnessUnavailable

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail?.isEmpty == false
                ? detail
                : "The installation didn’t finish. Check the install method and try again."
        case .harnessUnavailable:
            return "Codevisor couldn’t read the installation status. Check the machine connection and try again."
        }
    }
}
