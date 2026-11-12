import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountGuideScreen: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PluginAccountGuideModel
  let onSaved: () async -> Void

  var body: some View {
    NavigationStack {
      Form {
        if let step = model.currentStep {
          Section {
          } header: {
            Text(step.detail)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .textCase(nil)
          }
          PluginAccountGuideStepSection(step: step, model: model)
        }
        if let loadError = model.loadError {
          Section {
            Text(loadError).foregroundStyle(.secondary)
            Button("Try Again") { Task { await model.load() } }
          }
        }
      }
      .navigationTitle(model.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if model.isFirstStep {
            Button("Cancel", role: .cancel) { dismiss() }
          } else {
            Button("Back") { model.goBack() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(model.isLastStep ? "Connect" : "Next") { Task { await primaryAction() } }
            .disabled(!model.canContinue)
        }
      }
      .animation(.snappy(duration: 0.2), value: model.stepIndex)
      .task { await model.load() }
    }
  }

  private func primaryAction() async {
    guard model.isLastStep else {
      model.goForward()
      return
    }
    guard await model.save() != nil else { return }

    await onSaved()
    dismiss()
  }
}

private struct PluginAccountGuideStepSection: View {
  @Environment(\.openURL) private var openURL
  let step: ServerPluginAccountGuide.Step
  @Bindable var model: PluginAccountGuideModel

  var body: some View {
    Section {
      if let link = step.link, let url = URL(string: link.url) {
        Button(link.title) {
          openURL(url)
          model.goForward()
        }
        .disabled(!model.canContinue)
      }
      ForEach(model.fields(in: step)) { field in
        SecureField(field.label, text: text(for: field), prompt: Text(field.placeholder ?? field.label))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }
    } footer: {
      if let errorMessage = model.errorMessage {
        Text(errorMessage).foregroundStyle(.red)
      }
    }
  }

  private func text(for field: ServerConfigField) -> Binding<String> {
    Binding(
      get: { model.draft.values[field.key]?.text ?? "" },
      set: { model.draft.values[field.key] = $0.isEmpty ? nil : .string($0) }
    )
  }
}
