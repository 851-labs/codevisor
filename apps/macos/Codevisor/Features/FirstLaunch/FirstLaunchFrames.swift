import CodevisorCore
import SwiftUI

struct FirstLaunchFrames: Equatable {
  var icon: CGRect?
  var card: CGRect?
  var rows: [FirstLaunchStep: CGRect] = [:]
}
