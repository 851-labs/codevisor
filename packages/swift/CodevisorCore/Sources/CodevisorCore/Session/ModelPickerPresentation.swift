import Foundation

public struct ModelPickerPresentation: Equatable, Sendable {
  public enum ModelChip: Equatable, Sendable {
    case loading
    case selectModel
    case model(name: String)
  }

  public let modelChip: ModelChip
  public let showsSettingsChip: Bool
  public let showsSettingsSpinner: Bool

  public init(
    isModelListKnown: Bool,
    selectedModelName: String?,
    hasSettings: Bool,
    isResolvingSettings: Bool
  ) {
    guard isModelListKnown else {
      modelChip = .loading
      showsSettingsChip = false
      showsSettingsSpinner = false
      return
    }
    if let selectedModelName, !selectedModelName.isEmpty {
      modelChip = .model(name: selectedModelName)
    } else {
      modelChip = .selectModel
    }
    let settingsSpinner = isResolvingSettings && !hasSettings && selectedModelName?.isEmpty == false
    showsSettingsSpinner = settingsSpinner
    showsSettingsChip = hasSettings || settingsSpinner
  }

  public var modelChipTitle: String? {
    switch modelChip {
    case .loading: nil
    case .selectModel: "Select a model"
    case let .model(name): name
    }
  }
}
