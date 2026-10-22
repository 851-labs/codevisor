import ACPKit

struct ComposerSelectionIntent: Equatable {
  let harnessId: String
  let configValues: [String: String]
  let modelValue: String?
  var modelName: String? = nil

  @MainActor
  func canCarry(to capability: ServerHarnessCapability) -> Bool {
    guard let modelValue else { return true }
    guard let model = SessionController.modelOption(in: capability.configOptions) else { return false }
    return model.options.contains { $0.value == modelValue }
  }

  @MainActor
  func carriedConfigValues(to capability: ServerHarnessCapability) -> [String: String] {
    var carried = configValues
    if let modelValue,
      let model = SessionController.modelOption(in: capability.configOptions)
    {
      carried[model.id] = modelValue
    }
    return carried
  }

  @MainActor
  func compatibleConfigValues(in destinationOptions: [SessionConfigOption]) -> [String: String] {
    configValues.filter { configId, value in
      guard let option = destinationOptions.first(where: { $0.id == configId }) else {
        return false
      }
      return !SessionController.isModelOption(option) && option.options.contains { $0.value == value }
    }
  }

  func requestedSelections(
    modelOptionId: String,
    modelValue: String,
    over destinationValues: [String: String]
  ) -> [String: String] {
    var requested = destinationValues
    requested.merge(configValues) { _, carried in carried }
    requested[modelOptionId] = modelValue
    return requested
  }

  @MainActor
  func catalogModel(offering modelValue: String, in options: [SessionConfigOption]?) -> SessionConfigOption? {
    guard let options,
      let model = SessionController.modelOption(in: options),
      model.options.contains(where: { $0.value == modelValue })
    else { return nil }
    return model
  }

  func resolvedCapability(in response: ServerCapabilities) -> ServerHarnessCapability? {
    guard let capability = response.harnesses.first(where: { $0.harness.id == harnessId }),
      !capability.configOptions.isEmpty
    else { return nil }
    return capability
  }

  static func modelWasApplied(_ model: SessionConfigOption, in capability: ServerHarnessCapability) -> Bool {
    capability.unappliedConfigSelections?[model.id] == nil
      && model.options.contains { $0.value == model.currentValue }
  }

  @MainActor
  func resolveRememberedOptions(
    in options: inout [SessionConfigOption],
    resolvedModel: SessionConfigOption,
    resolvedModelValue: String,
    destinationValues: [String: String]
  ) -> [String: String] {
    var resolvedValues: [String: String] = [:]
    for index in options.indices
    where SessionController.rememberedConfigCategories.contains(options[index].category ?? "") {
      let option = options[index]
      let carriedValue =
        option.id == resolvedModel.id ? resolvedModelValue : configValues[option.id]
      let value = preferredValue(
        for: option,
        carriedValue: carriedValue,
        destinationValues: destinationValues
      )
      guard let value else { continue }
      options[index].currentValue = value
      resolvedValues[option.id] = value
    }
    return resolvedValues
  }

  private func preferredValue(
    for option: SessionConfigOption,
    carriedValue: String?,
    destinationValues: [String: String]
  ) -> String? {
    let acceptedCarriedValue = option.currentValue == carriedValue ? carriedValue : nil
    return [acceptedCarriedValue, destinationValues[option.id], option.currentValue]
      .compactMap { $0 }
      .first { candidate in
        option.options.contains { $0.value == candidate }
      }
  }
}
