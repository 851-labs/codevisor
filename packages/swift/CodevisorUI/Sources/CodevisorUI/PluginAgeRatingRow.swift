import CodevisorCore
import SwiftUI

public struct PluginAgeRatingRow: View {
  @Environment(AppEnvironment.self) private var environment
  private let subject: PluginModerationSubject

  public init(subject: PluginModerationSubject) {
    self.subject = subject
  }

  public var body: some View {
    let age = environment.pluginAccess.ageRating(for: subject)
    LabeledContent("Age Rating", value: age.map { "\($0)+" } ?? "Not rated")
  }
}
