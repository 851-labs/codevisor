import CodevisorCore
import CodevisorUI
import SwiftUI

/// The harness picker chip. Only shown while the harness can still be chosen
/// (an unsent draft); on a session page — including the moment a first send is
/// still connecting — it renders nothing.
struct HarnessPickerMenu: View {
    @Bindable var controller: SessionController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if controller.canChooseHarness {
            if controller.preparationState == .loading {
                // HIG: use a small, unlabeled indeterminate spinner for an
                // unpredictable background operation in a constrained control.
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 96)
                    .help("Checking available agents")
                    .accessibilityLabel("Checking available agents")
            } else if controller.preparationState == .failed {
                Button {
                    Task { await controller.prepare() }
                } label: {
                    PickerChip(text: "Agents unavailable") {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
                .buttonStyle(HoverIconButtonStyle(shape: .chip))
                .help("Couldn't load agents. Click to try again.")
                .accessibilityLabel("Agents unavailable. Try again")
            } else {
                Menu {
                    ForEach(controller.harnesses) { harness in
                        Toggle(
                            isOn: Binding(
                                get: { harness.id == controller.selectedHarnessId },
                                set: { isOn in
                                    guard isOn else { return }
                                    Task { await controller.selectHarness(harness.id) }
                                }
                            )
                        ) {
                            Label {
                                // Text-level dot: macOS menus drop SF Symbol
                                // decorations, so the update marker rides in
                                // the title string.
                                Text(
                                    harness.updateInfo?.updateAvailable == true
                                        ? "\(harness.name) •"
                                        : harness.name
                                )
                            } icon: {
                                HarnessIcon(
                                    harnessId: harness.id,
                                    fallbackSymbolName: harness.symbolName
                                )
                            }
                        }
                    }

                    if !controller.harnesses.isEmpty {
                        Divider()
                    }

                    Button("Manage Harnesses…") {
                        SettingsRouter.shared.showHarnesses()
                        openSettings()
                    }
                } label: {
                    PickerChip(
                        text: controller.harnesses.isEmpty
                            ? "No agent installed"
                            : controller.selectedHarness?.name ?? "Choose agent"
                    ) {
                        if let harness = controller.selectedHarness {
                            HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName)
                        }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(HoverIconButtonStyle(shape: .chip))
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}
