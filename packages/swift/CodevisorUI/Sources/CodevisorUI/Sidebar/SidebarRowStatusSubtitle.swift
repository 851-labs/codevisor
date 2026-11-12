import SwiftUI

public struct SidebarRowStatusSubtitle<SubtitleText: View>: View {
  let status: SidebarRowStatus?
  let subtitle: String?
  let subtitleText: (String) -> SubtitleText

  public init(
    status: SidebarRowStatus?, subtitle: String?, @ViewBuilder subtitleText: @escaping (String) -> SubtitleText
  ) {
    self.status = status
    self.subtitle = subtitle
    self.subtitleText = subtitleText
  }

  public var body: some View {
    HStack(spacing: 0) {
      if let status {
        SidebarRowStatusLabel(status: status, showsIcon: false)
      }
      if let subtitle {
        subtitleText(SidebarRowSubtitle.text(subtitle, followingStatus: status != nil))
      }
    }
  }
}
