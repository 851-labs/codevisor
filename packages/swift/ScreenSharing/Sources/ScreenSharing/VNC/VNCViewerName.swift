import Foundation

public enum VNCViewerName {
  public static var thisDevice: String {
    #if os(macOS)
      Host.current().localizedName ?? "Another Mac"
    #else
      "Another device"
    #endif
  }
}
