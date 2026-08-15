import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

/// Manual pairing: address + token, validated against the server before the
/// machine is saved (the iOS mirror of the macOS Add Remote Machine form).
/// Styled like the system "Join Wi-Fi Network" sheet: circular close/confirm
/// buttons, a centered tinted glyph, a leading large title, and label-led
/// form rows. The QR/deeplink flow covers the common path; this is the
/// fallback for typing coordinates from `codevisor setup`. Shared with
/// onboarding.
struct AddMachineSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var host: String
    @State private var name: String
    @State private var token = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    /// Prefill support for the tailnet-discovery rows; the manual add flow
    /// uses the empty defaults.
    init(initialHost: String = "", initialName: String = "") {
        _host = State(initialValue: initialHost)
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    labeledField("Address") {
                        TextField("Host or host:port", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                Section {
                    labeledField("Name") {
                        TextField("Optional", text: $name)
                    }
                    labeledField("Token") {
                        SecureField("Connection token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    InlineCodeText(
                        "Run `codevisor token` on the machine, or copy it from the `codevisor setup` output.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// The Join-Wi-Fi-style top area: X and ✓ in circles, a centered tinted
    /// glyph, and the leading large title.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .scaledFrame(width: 22, height: 22, relativeTo: .title3)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Cancel")
                Spacer()
                Button {
                    add()
                } label: {
                    Group {
                        if isAdding {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                                .font(.title3.weight(.semibold))
                        }
                    }
                    .scaledFrame(width: 22, height: 22, relativeTo: .title3)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(host.isEmpty || isAdding)
                .accessibilityLabel("Add")
            }
            Image(systemName: "desktopcomputer")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            Text("Add Machine")
                .font(.title.bold())
                .padding(.top, 28)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// A native settings form row: leading label, then the field inline.
    private func labeledField(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(label)
            field()
        }
    }

    private func add() {
        isAdding = true
        errorMessage = nil
        Task {
            do {
                let machine = try await environment.machines.addRemoteValidating(
                    host: host,
                    name: name.isEmpty ? nil : name,
                    token: token.isEmpty ? nil : token
                )
                environment.machines.selectMachine(machine.id)
                await environment.prepareSelectedMachine()
                dismiss()
            } catch {
                errorMessage = ErrorReporter.userFacingMessage(for: error)
                isAdding = false
            }
        }
    }
}
