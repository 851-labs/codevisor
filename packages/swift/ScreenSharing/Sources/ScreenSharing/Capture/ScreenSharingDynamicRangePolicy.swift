#if os(macOS)
  import AppKit

  /// When a host sends HDR (851-2380), shared by the product host and the rig.
  public enum ScreenSharingDynamicRangePolicy {
    /// What to send, and why not HDR when the viewer can show it: the negotiated codec needs a
    /// 10-bit profile (Main 4:4:4) and the captured display needs headroom (an XDR panel, an HDR
    /// preset; a virtual display for Dynamic Resolution has none).
    public static func decide(
      viewerSupports: Bool, codec: ScreenSharingVideoCodec?, displayHeadroom: CGFloat
    ) -> (range: ScreenSharingDynamicRange, reason: String?) {
      guard viewerSupports else { return (.standard, nil) }
      guard codec?.supportsHighDynamicRange == true else { return (.standard, "The video codec has no HDR profile.") }
      guard displayHeadroom > 1 else { return (.standard, "The shared display can't show HDR.") }
      return (.high, nil)
    }

    /// The most a display can show above SDR white: 1 for an SDR display, or one that isn't online.
    @MainActor
    public static func headroom(of display: CGDirectDisplayID) -> CGFloat {
      let screen = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
      }
      return screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
    }
  }
#endif
