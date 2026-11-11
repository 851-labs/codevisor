import SwiftUI

public struct UnreadMenuItem: View {
  let isUnread: Bool
  let setUnread: (Bool) -> Void

  public init(isUnread: Bool, setUnread: @escaping (Bool) -> Void) {
    self.isUnread = isUnread
    self.setUnread = setUnread
  }

  public var body: some View {
    Button {
      setUnread(!isUnread)
    } label: {
      Label(title, systemImage: systemImage)
        .labelStyle(.titleAndIcon)
    }
  }

  private var title: String {
    isUnread ? "Mark as Read" : "Mark as Unread"
  }

  private var systemImage: String {
    isUnread ? "message" : "message.badge"
  }
}
