import ACPKit
import CodevisorCore
import SwiftUI

/// The model / thinking-level chip — "Sonnet High" — opening the searchable
/// model sheet (model → thinking → speed, grouped by harness for new chats).
struct ModelConfigChip: View {
    @Bindable var controller: SessionController
    @State private var showsPicker = false

    private var isFastSpeed: Bool { controller.speedOption?.currentValue == "fast" }

    var body: some View {
        if controller.isLoadingModelMenu {
            ProgressView()
                .controlSize(.small)
        } else if controller.hasModelMenu {
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
                        // Weight + color together carry the hierarchy (HIG:
                        // don't rely on color alone to distinguish levels).
                        Text(model.currentName)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
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
            .sheet(isPresented: $showsPicker) {
                ModelPickerSheet(controller: controller)
            }
        }
    }
}
