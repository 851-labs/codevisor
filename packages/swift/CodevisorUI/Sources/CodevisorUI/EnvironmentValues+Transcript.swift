import SwiftUI
import CodevisorCore
import StreamMarkdown

extension EnvironmentValues {
  @Entry public var transcriptDisclosure: TranscriptDisclosureStore?

  @Entry public var runningSubagentToolCallIds: Set<String> = []

  @Entry public var openSubagent: OpenSubagentAction?

  @Entry public var transcriptController: SessionController?

  @Entry public var transcriptPerformAnchoredDisclosureChange: TranscriptAnchoredDisclosureChangeAction?

  @Entry public var transcriptInvalidateRowMeasurement: TranscriptRowMeasurementInvalidationAction?

  @Entry public var transcriptAttachmentThumbnail: TranscriptAttachmentThumbnail?

  @Entry public var transcriptWebLinkActions: MarkdownWebLinkActions?

  @Entry public var pluginAppHost: PluginAppHost?

  @Entry public var pluginAppPresenter: PluginAppPresenter?
}

public struct TranscriptAttachmentThumbnail: @unchecked Sendable {
  private let make: (PreviewFile) -> AnyView

  public init(_ make: @escaping (PreviewFile) -> AnyView) {
    self.make = make
  }

  @MainActor public func callAsFunction(_ file: PreviewFile) -> AnyView { make(file) }
}

public struct TranscriptAnchoredDisclosureChangeAction: Sendable {
  private let handler: @MainActor @Sendable (_ change: @escaping () -> Void) -> Void

  public init(_ handler: @escaping @MainActor @Sendable (_ change: @escaping () -> Void) -> Void) {
    self.handler = handler
  }

  @MainActor public func callAsFunction(_ change: @escaping () -> Void) { handler(change) }
}

public struct TranscriptRowMeasurementInvalidationAction: Sendable {
  private let handler: @MainActor @Sendable () -> Void

  public init(_ handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }

  @MainActor public func callAsFunction() { handler() }
}

public struct OpenSubagentAction: Sendable {
  public enum Placement: Sendable {
    case automatic
    case split
    case newTab
  }

  private let handler:
    @MainActor @Sendable (_ parentSessionId: UUID, _ toolCallId: String, _ title: String, _ placement: Placement)
      -> Void

  public init(
    _ handler: @escaping @MainActor @Sendable (UUID, String, String, Placement) -> Void
  ) { self.handler = handler }

  @MainActor public func callAsFunction(
    parentSessionId: UUID, toolCallId: String, title: String, placement: Placement = .automatic
  ) {
    handler(parentSessionId, toolCallId, title, placement)
  }
}
