import CodevisorCore
import SwiftUI

public struct PluginAgeRatingRow: View {
  @Environment(AppEnvironment.self) private var environment
  private let pluginId: String
  private let declared: Int?

  public init(pluginId: String, declared: Int?) {
    self.pluginId = pluginId
    self.declared = declared
  }

  public var body: some View {
    let age = environment.pluginAccess.ageRating(pluginId: pluginId, declared: declared)
    LabeledContent("Age Rating", value: age.map { "\($0)+" } ?? "Not rated")
  }
}
