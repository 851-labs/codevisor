import SwiftUI

CVRegisterChromiumMallocZone()
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
  } else if MenuBarMode.isEnabled {
    MenuBarCodevisorApp.main()
  } else {
    CodevisorApp.main()
  }
#else
  if MenuBarMode.isEnabled {
    MenuBarCodevisorApp.main()
  } else {
    CodevisorApp.main()
  }
#endif
