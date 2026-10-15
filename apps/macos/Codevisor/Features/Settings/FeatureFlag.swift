import CodevisorCore
import SwiftUI

enum FeatureFlag: String, CaseIterable, Identifiable {
  case workspaceInspector

  var id: String { rawValue }

  var preferenceKey: String { "featureFlags.\(rawValue)" }

  var title: String {
    switch self {
    case .workspaceInspector: "Workspace Inspector"
    }
  }

  var detail: String {
    switch self {
    case .workspaceInspector: "Adds a right sidebar to each workspace with its tools and details."
    }
  }

  @MainActor
  var isEnabled: Bool {
    get { ClientPreferences.shared.value(forKey: preferenceKey, default: false) }
    nonmutating set { ClientPreferences.shared.set(newValue, forKey: preferenceKey) }
  }
}
