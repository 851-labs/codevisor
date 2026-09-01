import ACPKit
import CodevisorCore
import SwiftUI

/// The model / thinking-level chip — "Sonnet High" — opening the searchable
/// model sheet (model → thinking → speed, grouped by harness for new chats).
struct ModelConfigChip: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var controller: SessionController
    @State private var showsPicker = false

    private var isFastSpeed: Bool { controller.speedOption?.currentValue == "fast" }

    private var canOpenPicker: Bool {
        controller.hasModelMenu || controller.canChooseHarness
    }

    private var fallbackLabel: String {
        let needsSignIn = !environment.configCache
            .signInRequired(forServer: controller.project.serverId).isEmpty
        if needsSignIn || controller.preparationState == .failed {
            return "Select a harness…"
        }
        return "Choose model"
    }

    var body: some View {
        Group {
            if controller.isLoadingModelMenu {
                ProgressView()
                    .controlSize(.small)
            } else if canOpenPicker {
                Button {
                    showsPicker = true
                } label: {
                    HStack(spacing: 5) {
                        if isFastSpeed {
                            Image(systemName: "bolt.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let model = controller.modelOption {
                            Text(model.currentName)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text(fallbackLabel)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        ForEach(controller.thoughtLevelOptions) { thought in
                            Text(thought.currentName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Model settings")
            }
        }
        // Keep the presenter mounted while the catalog changes. A conditional
        // presenter caused the sheet to dismiss as soon as an auth-only result
        // removed the last model menu.
        .sheet(isPresented: $showsPicker) {
            ModelPickerSheet(controller: controller)
        }
    }
}
