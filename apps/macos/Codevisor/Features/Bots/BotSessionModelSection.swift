import ACPKit
import CodevisorCore
import SwiftUI

struct BotSessionModelSection: View {
  @Bindable var controller: SessionController
  let harnessId: String

  var body: some View {
    Section("Model") {
      if let model = controller.modelOption {
        Picker("Model", selection: modelSelection(model)) {
          ForEach(model.options) { option in
            Text(option.name).tag(option.value)
          }
        }
        .pickerStyle(.menu)
        ForEach(ModelParameterMenu.options(from: controller.configOptions)) { option in
          Picker(option.name, selection: parameterSelection(option)) {
            ForEach(option.options) { value in
              Text(value.name).tag(value.value)
            }
          }
          .pickerStyle(.menu)
        }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .disabled(controller.pendingModelPick != nil)
  }

  private func modelSelection(_ model: SessionConfigOption) -> Binding<String> {
    Binding(
      get: { controller.pendingModelPick?.value ?? model.currentValue },
      set: { value in
        guard value != model.currentValue, let option = model.options.first(where: { $0.value == value }) else {
          return
        }
        Task { await controller.chooseModel(value, name: option.name, harnessId: activeHarnessId) }
      }
    )
  }

  private func parameterSelection(_ option: SessionConfigOption) -> Binding<String> {
    Binding(
      get: { option.currentValue },
      set: { value in
        guard value != option.currentValue else { return }
        Task { await controller.setConfigOption(option.id, value) }
      }
    )
  }

  private var activeHarnessId: String {
    controller.activeHarnessId ?? harnessId
  }
}
