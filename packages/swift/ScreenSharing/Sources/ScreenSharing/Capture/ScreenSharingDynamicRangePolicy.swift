#if os(macOS)
  import AppKit

  public enum ScreenSharingDynamicRangePolicy {
    public static func decide(
      viewerSupports: Bool, codec: ScreenSharingVideoCodec?, displayHeadroom: CGFloat
    ) -> (range: ScreenSharingDynamicRange, reason: String?) {
      guard viewerSupports else { return (.standard, nil) }
      guard codec?.supportsHighDynamicRange == true else { return (.standard, "The video codec has no HDR profile.") }
      guard displayHeadroom > 1 else { return (.standard, "The shared display can't show HDR.") }
      return (.high, nil)
    }

    @MainActor
    public static func headroom(of display: CGDirectDisplayID) -> CGFloat {
      let screen = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
      }
      return screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
    }
  }
#endif
