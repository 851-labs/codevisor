import CodevisorCore
import SwiftUI

struct SetupRequestSheet: View {
  let request: TranscriptSetupRequest
  let controller: SessionController

  var body: some View {
    switch request.kind {
    case .computerUse:
      ComputerUseSetupSheet(request: request, controller: controller)
    case .chromeExtension:
      ChromeExtensionSetupSheet(request: request, controller: controller)
    }
  }
}
