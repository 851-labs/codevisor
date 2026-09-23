import SwiftUI
import UIKit

extension WorkspaceScreen {
  /// iPhone Duo's inner display is short, so beside a tiled sidebar the
  /// title (which repeats the selected row) gives its height back to the
  /// transcript. iPad always shows it.
  var hidesTitleBesideSidebar: Bool {
    homeSidebarIsTiled && UIDevice.current.userInterfaceIdiom == .phone
  }
}
