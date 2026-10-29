import CoreGraphics

enum TranscriptPluginAppRowProjection {
  static let appEstimatedHeight: CGFloat = 252

  static func append(
    _ message: AssistantMessage,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) -> Bool {
    let apps = TranscriptPluginApps.apps(of: message.turn)
    guard !apps.isEmpty else { return false }
    let id: TranscriptPresentationRow.ID =
      switch lifecycle {
      case .receiving: .activePluginApps(message.id)
      case .settled: .assistantPluginApps(message.id)
      }
    rows.append(
      .init(
        id: id,
        content: .pluginApps(apps),
        estimatedHeight: CGFloat(apps.count) * appEstimatedHeight,
        measurementRevision: apps.count,
        spacingAfter: 14
      ))
    return true
  }
}
