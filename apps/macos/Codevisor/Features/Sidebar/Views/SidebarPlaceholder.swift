import CodevisorCore
import SwiftUI

struct SidebarPlaceholder: View {
  @Environment(AppEnvironment.self) private var environment
  let icon: Image
  let title: String
  let message: String

  var body: some View {
    if hasLoaded {
      ContentUnavailableView {
        Label {
          Text(title)
        } icon: {
          icon
        }
      } description: {
        Text(message)
      }
      .containerRelativeFrame(.vertical)
    }
  }

  private var hasLoaded: Bool {
    environment.navigationLaunch(hasVisibleContent: false) != .loading
  }
}
