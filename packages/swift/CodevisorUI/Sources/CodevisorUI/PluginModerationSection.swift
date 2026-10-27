import CodevisorCore
import SwiftUI

public struct PluginModerationSection: View {
  let subject: PluginModerationSubject

  public init(server: ServerMcpServer) {
    subject = PluginModerationSubject(server: server)
  }

  public var body: some View {
    Section {
      LabeledContent("Publisher") {
        HStack(spacing: 8) {
          Text(subject.publisher)
          PluginSafetyButton(subject: subject)
        }
      }
      PluginAgeRatingRow(subject: subject)
    }
  }
}
