import SwiftUI

#if DEBUG
  if let directory = BentoRender.outputDirectory {
    BentoRender.run(into: directory)
  }
  if let directory = BentoNotifications.handshakeDirectory {
    BentoNotifications.run(handshake: directory)
  }
#endif
CVPrepareChromiumApplication()
#if DEBUG
  if AppStoreScreenshotData.isEnabled {
    AppStoreScreenshotApp.main()
  } else if SandboxMode.isEnabled {
    SandboxCodevisorApp.main()
  } else {
    CodevisorApp.main()
  }
#else
  if SandboxMode.isEnabled {
    SandboxCodevisorApp.main()
  } else {
    CodevisorApp.main()
  }
#endif
