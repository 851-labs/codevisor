import ACPKit
import CodevisorCore
import SwiftUI

/// A remaining harness config option (anything that isn't model/thinking/speed)
/// as its own chip, mirroring the macOS toolbar.
struct ConfigChip: View {
    @Bindable var controller: SessionController
    let option: SessionConfigOption

    var body: some View {
        Menu {
            Picker(
                option.name,
                selection: Binding(
                    get: { controller.configOptions.first { $0.id == option.id }?.currentValue ?? option.currentValue },
                    set: { value in Task { await controller.setConfigOption(option.id, value) } }
                )
            ) {
                ForEach(option.options) { value in
                    Text(value.name).tag(value.value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(option.currentName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
    }
}
