import SwiftUI
import TranscriptKit

public struct UserMessageAttributionLabel: View {
  let text: MessageAttributionText

  public init?(_ attribution: UserMessageAttribution?) {
    guard let text = MessageAttributionText(attribution) else { return nil }
    self.text = text
  }

  public var body: some View {
    HStack {
      Spacer(minLength: 0)
      text
    }
  }
}
