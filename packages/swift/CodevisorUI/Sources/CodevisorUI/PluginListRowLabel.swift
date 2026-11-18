import SwiftUI

public struct PluginListRowLabel: View {
  private let summary: PluginListSummary

  public init(_ summary: PluginListSummary) {
    self.summary = summary
  }

  public var body: some View {
    LabeledContent(summary.page.title) {
      if summary.isLoading {
        ProgressView().controlSize(.small)
      } else {
        Text(summary.count, format: .number)
      }
    }
    .foregroundStyle(.primary)
  }
}
