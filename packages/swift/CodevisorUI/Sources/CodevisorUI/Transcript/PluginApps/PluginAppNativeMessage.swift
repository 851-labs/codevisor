import CoreGraphics
import Foundation

public enum PluginAppNativeMessage: Equatable, Sendable {
  case size(height: CGFloat)
  case openLink(URL)
  case message(String, viewId: String)
  case displayMode(PluginAppDisplayMode, requestId: String?)
  case appModes(Set<PluginAppDisplayMode>)
  case frameFailed

  public static let heightRange: ClosedRange<CGFloat> = 80...720

  private static let externalSchemes: Set<String> = ["http", "https", "mailto"]

  public init?(body: Any) {
    guard let payload = body as? [String: Any], let type = payload["type"] as? String else { return nil }

    switch type {
    case "size": self.init(size: payload["height"])
    case "openLink": self.init(link: payload["url"])
    case "message": self.init(text: payload["text"], viewId: payload["viewId"])
    case "displayMode": self.init(mode: payload["mode"], requestId: payload["requestId"])
    case "appModes": self.init(modes: payload["modes"])
    case "frameFailed": self = .frameFailed
    default: return nil
    }
  }

  public static func clampedHeight(_ height: CGFloat) -> CGFloat {
    min(max(height.rounded(.up), heightRange.lowerBound), heightRange.upperBound)
  }

  public static func externalURL(_ url: URL) -> URL? {
    guard let scheme = url.scheme?.lowercased(), externalSchemes.contains(scheme) else { return nil }
    return url
  }

  private init?(size value: Any?) {
    guard let height = (value as? NSNumber)?.doubleValue, height.isFinite else { return nil }
    self = .size(height: Self.clampedHeight(CGFloat(height)))
  }

  private init?(link value: Any?) {
    guard let text = value as? String, let url = URL(string: text), let external = Self.externalURL(url)
    else { return nil }
    self = .openLink(external)
  }

  private init?(text value: Any?, viewId: Any?) {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
      let viewId = viewId as? String, !viewId.isEmpty
    else { return nil }
    self = .message(text, viewId: viewId)
  }

  private init?(mode value: Any?, requestId: Any?) {
    guard let mode = PluginAppDisplayMode.parse(value) else { return nil }
    self = .displayMode(mode, requestId: requestId as? String)
  }

  private init?(modes value: Any?) {
    guard let list = value as? [Any] else { return nil }
    self = .appModes(Set(list.compactMap(PluginAppDisplayMode.parse)))
  }
}
