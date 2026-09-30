import Foundation

/// What the composer's model controls show, derived from controller state.
///
/// A spinner appears only when there is nothing to show yet — never beside
/// a value that is merely being refreshed. So at most one is ever visible:
/// - The model list is unknown: a single spinner replaces the model chip and
///   no parameters chip is shown.
/// - The list is known: the chip names the selected model, or reads
///   "Select a model" when there is no valid pick. A background refresh of
///   a known list keeps showing it, with no spinner.
/// - A selected model whose settings are not known yet: the parameters chip
///   is a spinner until they arrive. Settings already on screen stay put
///   (without a spinner) while fresher ones load.
public struct ModelPickerPresentation: Equatable, Sendable {
  public enum ModelChip: Equatable, Sendable {
    /// The model list is not known yet.
    case loading
    /// The list is known but nothing valid is selected.
    case selectModel
    /// The selected model's display name.
    case model(name: String)
  }

  public let modelChip: ModelChip
  /// Whether the parameters chip is shown at all.
  public let showsSettingsChip: Bool
  /// The parameters chip is a spinner: a selected model's settings are
  /// loading and none are known to show meanwhile.
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
    // Settings only belong to a selected model, and a spinner only stands
    // in for settings there is nothing cached to show for.
    let settingsSpinner = isResolvingSettings && !hasSettings && selectedModelName?.isEmpty == false
    showsSettingsSpinner = settingsSpinner
    showsSettingsChip = hasSettings || settingsSpinner
  }

  /// The number of spinners this presentation renders; never more than one.
  public var spinnerCount: Int {
    (modelChip == .loading ? 1 : 0) + (showsSettingsSpinner ? 1 : 0)
  }

  /// The model chip's text when it is not loading.
  public var modelChipTitle: String? {
    switch modelChip {
    case .loading: nil
    case .selectModel: "Select a model"
    case let .model(name): name
    }
  }
}
