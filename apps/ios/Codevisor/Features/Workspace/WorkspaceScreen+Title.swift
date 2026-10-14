import SwiftUI
import UIKit

extension WorkspaceScreen {
  var hidesTitleBesideSidebar: Bool {
    homeSidebarIsTiled && UIDevice.current.userInterfaceIdiom == .phone
  }
}
