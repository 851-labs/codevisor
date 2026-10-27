import Foundation

struct PluginAppLoadRequest: Equatable {
  var hasSubject: Bool
  var restriction: String?
  var display: PluginAppDisplay
  var showsElsewhere = false

  var showsPage: Bool {
    hasSubject && restriction == nil && !showsElsewhere
  }
}
