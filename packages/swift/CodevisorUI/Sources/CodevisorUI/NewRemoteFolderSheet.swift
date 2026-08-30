import CodevisorCore
import SwiftUI

/// Shared naming sheet for the macOS and iOS remote project browsers.
/// Creation errors stay inline so a failed request never discards the name.
public struct NewRemoteFolderSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var model: RemoteDirectoryCreationModel
    @FocusState private var nameFieldFocused: Bool

    private let parentPath: String
    private let existingNames: Set<String>
    private let onCreated: @MainActor (String) -> Void

    public init(
        machineName: String,
        parentPath: String,
        existingNames: Set<String>,
        create: @escaping RemoteDirectoryCreationModel.Creator,
        onCreated: @escaping @MainActor (String) -> Void
    ) {
        self.parentPath = parentPath
        self.existingNames = existingNames
        self.onCreated = onCreated
        _model = State(
            initialValue: RemoteDirectoryCreationModel(
                machineName: machineName,
                create: create
            )
        )
    }

    public var body: some View {
        #if os(macOS)
            macOSBody
        #else
            iOSBody
        #endif
    }

    #if os(macOS)
        private var macOSBody: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("New Folder")
                    .font(.headline)

                folderNameField

                if let message = displayedMessage {
                    errorLabel(message)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isCreating)
                    Button(action: createFolder) {
                        if model.isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || model.isCreating)
                }
            }
            .padding(20)
            .frame(width: 360)
            .interactiveDismissDisabled(model.isCreating)
            .task { nameFieldFocused = true }
        }
    #else
        private var iOSBody: some View {
            NavigationStack {
                Form {
                    Section {
                        folderNameField
                            .textInputAutocapitalization(.never)
                    }
                    if let message = displayedMessage {
                        Section {
                            errorLabel(message)
                        }
                    }
                }
                .navigationTitle("New Folder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(model.isCreating)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: createFolder) {
                            if model.isCreating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Create")
                            }
                        }
                        .disabled(!canCreate || model.isCreating)
                    }
                }
            }
            .interactiveDismissDisabled(model.isCreating)
            .task { nameFieldFocused = true }
        }
    #endif

    private var folderNameField: some View {
        TextField("Name", text: $name)
            .focused($nameFieldFocused)
            .onSubmit(createFolder)
            .disabled(model.isCreating)
            .onChange(of: name) { _, _ in model.clearError() }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(message)")
    }

    private var validationMessage: String? {
        RemoteDirectoryCreationModel.validationMessage(
            for: name,
            existingNames: existingNames
        )
    }

    private var displayedMessage: String? {
        if let errorMessage = model.errorMessage { return errorMessage }
        guard !name.isEmpty else { return nil }
        return validationMessage
    }

    private var canCreate: Bool {
        validationMessage == nil
    }

    private func createFolder() {
        guard canCreate, !model.isCreating else { return }
        Task { @MainActor in
            if let path = await model.createFolder(
                named: name,
                in: parentPath,
                existingNames: existingNames
            ) {
                onCreated(path)
                dismiss()
            } else {
                nameFieldFocused = true
            }
        }
    }
}
