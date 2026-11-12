import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountGuideSetupSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Bindable var model: PluginAccountGuideModel
  let onSaved: () async -> Void

  var body: some View {
    SetupSheet(
      symbol: "puzzlepiece.extension",
      title: model.title,
      subtitle: model.currentStep?.detail ?? model.spec.guide?.summary,
      primaryTitle: primaryTitle,
      canContinue: model.canContinue,
      onCancel: { dismiss() },
      onBack: model.isFirstStep ? nil : { model.goBack() },
      onContinue: primaryAction,
      stepsInCard: false,
      icon: AnyView(PluginAccountGuideIcon(model: model, side: 40))
    ) {
      if let step = model.currentStep, !model.fields(in: step).isEmpty || model.errorMessage != nil {
        PluginAccountGuideStepInput(step: step, model: model)
          .id(step.id)
      }
      if let loadError = model.loadError {
        PluginAccountGuideLoadError(message: loadError) { Task { await model.load() } }
      }
    }
    .disabled(model.isSaving)
    .animation(.snappy(duration: 0.2), value: model.stepIndex)
    .task { await model.load() }
  }

  private var primaryTitle: String {
    if let link = model.currentStep?.link { return link.title }
    return model.isLastStep ? "Connect" : "Next"
  }

  private func primaryAction() {
    if let link = model.currentStep?.link, let url = URL(string: link.url) {
      openURL(url)
      model.goForward()
      return
    }
    guard model.isLastStep else {
      model.goForward()
      return
    }
    Task {
      guard await model.save() != nil else { return }

      await onSaved()
      dismiss()
    }
  }
}

private struct PluginAccountGuideStepInput: View {
  let step: ServerPluginAccountGuide.Step
  @Bindable var model: PluginAccountGuideModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.fields(in: step)) { field in
        PluginAccountGuideField(field: field, value: $model.draft.values[field.key])
      }
      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct PluginAccountGuideLoadError: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Try Again", action: onRetry)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct PluginAccountGuideField: View {
  let field: ServerConfigField
  @Binding var value: ServerConfigFieldValue?

  var body: some View {
    input
      .textFieldStyle(.roundedBorder)
      .controlSize(.large)
      .labelsHidden()
  }

  @ViewBuilder
  private var input: some View {
    if field.isSecret {
      SecureField(field.label, text: text, prompt: prompt)
    } else {
      TextField(field.label, text: text, prompt: prompt)
    }
  }

  private var prompt: Text { Text(field.placeholder ?? field.label) }

  private var text: Binding<String> {
    Binding(
      get: { value?.text ?? "" },
      set: { value = $0.isEmpty ? nil : .string($0) }
    )
  }
}
