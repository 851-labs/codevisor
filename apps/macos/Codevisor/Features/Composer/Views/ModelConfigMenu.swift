import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// The combined model dropdown: one chip that opens nested menus for the
/// model, thinking level, and speed. Collapsed it reads
/// "[⚡ when fast] Model ThinkingLevel" — the model in the normal text color,
/// the thinking level subdued.
struct ModelConfigMenu: View {
    @Bindable var controller: SessionController

    var body: some View {
        if controller.isLoadingModelMenu {
            // Keep the toolbar stable while a resumed runtime supplies its
            // session-specific model, reasoning, and speed options.
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 96)
                .help("Loading model settings")
                .accessibilityLabel("Loading model settings")
        } else if controller.hasModelMenu {
            Menu {
                if controller.isConnectingToHarness {
                    Label("Connecting to harness…", systemImage: "arrow.triangle.2.circlepath")
                        .disabled(true)
                } else {
                    if let option = controller.modelOption {
                        section("Model", option)
                    }
                    ForEach(controller.thoughtLevelOptions) { option in
                        section(option.name, option)
                    }
                    if let option = controller.speedOption {
                        section("Speed", option)
                    }
                }
            } label: {
                chipLabel
            }
            .menuStyle(.button)
            .buttonStyle(HoverIconButtonStyle(shape: .chip))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model, thinking level, and speed")
            .accessibilityLabel("Model settings")
            .accessibilityValue(accessibilityValue)
        }
    }

    // Toggles rather than checkmark labels: macOS menus drop SF Symbol images,
    // so only a Toggle reliably renders the native selected checkmark.
    // Flat titled sections rather than nested submenus: everything is one
    // click away and the current value of each group is scannable at once.
    private func section(_ title: String, _ option: SessionConfigOption) -> some View {
        Section(title) {
            ForEach(option.options) { value in
                Toggle(
                    isOn: Binding(
                        get: {
                            controller.configOptions.first { $0.id == option.id }?.currentValue
                                == value.value
                        },
                        set: { isOn in
                            guard isOn else { return }
                            Task { await controller.setConfigOption(option.id, value.value) }
                        }
                    )
                ) {
                    Text(value.name)
                }
                .help(value.description ?? "")
            }
        }
    }

    private var isFastSpeed: Bool {
        controller.speedOption?.currentValue == "fast"
    }

    private var accessibilityValue: String {
        ([controller.modelOption?.currentName].compactMap { $0 }
            + controller.thoughtLevelOptions.map(\.currentName)
            + [controller.speedOption?.currentName].compactMap { $0 })
            .joined(separator: ", ")
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {
            if isFastSpeed {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Fast speed")
            }
            if let model = controller.modelOption {
                Text(model.currentName)
                    .foregroundStyle(.primary)
            }
            ForEach(controller.thoughtLevelOptions) { thought in
                Text(thought.currentName)
                    .foregroundStyle(.secondary)
            }
        }
        // Cover the whole chip (including gaps) so a click anywhere opens it.
        .contentShape(Rectangle())
    }
}
